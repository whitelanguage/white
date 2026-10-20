// src/compiler/machine/x86_64/module.wl
import * from "model.wl"
import * from "../../wir/model.wl"
import * from "encoder.wl"
import * from "allocator.wl"
import * from "memory.wl"
import * from "abi.wl"
import * from "sse.wl"
import * from "abi/sysv.wl"
import x86_address_symbol, x86_emit_globals from "data.wl"
import WirReachability, wir_reachable_symbols from "../../wir/deadcode.wl"
import * from "lowering.wl"
import * from "types.wl"
import * from "values.wl"
import machine_lower_remainders from "../remainder.wl"
import machine_lower_wide_conversions from "../numeric.wl"
import machine_layout_valid from "../layout.wl"


func x86_module_error(message: String) -> X86ModuleResult {
    return X86ModuleResult(bytes=[], errors=[message], relocations=[], symbols=[], sections=[]);
}

func x86_patch_calls(ref program: WirModule, ref output: X86CodeBuffer, codes: Vector(X86FunctionCode)) -> Bool {
    let offsets: Vector(Int) = [];
    let i: Int = 0;
    while (i < program.arena.functions.length()) {
        offsets.append(-1);
        i++;
    }
    i = 0;
    while (i < codes.length()) {
        offsets[wir_id_index(UInt32(codes[i].function))] = codes[i].offset;
        i++;
    }

    let code_index: Int = 0;
    while (code_index < codes.length()) {
        let code: X86FunctionCode = codes[code_index];

        let call_index: Int = 0;
        while (call_index < code.calls.length()) {
            let call: X86CallFixup = code.calls[call_index];
            let target_index: Int = wir_id_index(UInt32(call.target));
            if (target_index < 0 || target_index >= program.arena.functions.length()) { return false; }
            if (program.arena.functions[target_index].linkage == WirLinkage.External) {
                call_index += 1;
                continue;
            }
            let target_offset: Int = offsets[target_index];
            if (target_offset < 0) { return false; }

            let patch_offset: Int = code.offset + call.offset;
            let displacement: Int = target_offset - (patch_offset + 4);
            if (displacement < -2147483648 || displacement > 2147483647) { return false; }

            if (!x86_patch_i32(ref output, patch_offset, displacement)) { return false; }

            call_index++;
        }

        code_index++;
    }

    return true;
}

func x86_lower_module(ref program: WirModule, verbose: Bool = false) -> X86ModuleResult {
// required legalization runs here before functions share the final type layouts
    let is_windows: Bool = program.target == "x86_64-pc-windows-msvc";
    let is_linux: Bool = program.target == "x86_64-unknown-linux-gnu";
    if ((!is_windows && !is_linux) || !machine_layout_valid(program)) {
        return x86_module_error("the x86_64 machine backend does not support this target");
    }
    x86_set_sysv_abi(is_linux);
    let rem_error = machine_lower_remainders(ref program);
    if (rem_error.length() != 0) { return x86_module_error(rem_error); }
    let numeric_error = machine_lower_wide_conversions(ref program);
    if (numeric_error.length() != 0) { return x86_module_error(numeric_error); }
    let codes: Vector(X86FunctionCode) = [];
    let layouts: Vector(WirTypeLayout) = x86_type_layouts(ref program);
    let relocations: Vector(X86Relocation) = [];
    let symbols: Vector(X86Symbol) = [];
    let output: X86CodeBuffer = x86_new_code_buffer();
    let reachable: WirReachability = wir_reachable_symbols(program);
    let retain_function: WirFuncID = x86_find_function(ref program, "__wl_retain");
    let release_function: WirFuncID = x86_find_function(ref program, "__wl_release");
    // checks share two runtime targets, resolve them once rather than searching
    // every function name again for each checked load and index operation.
    let null_function: WirFuncID = x86_find_function(ref program, "__wl_fail_null");
    let bounds_function: WirFuncID = x86_find_function(ref program, "__wl_fail_bounds");
    if verbose {
        print("Emitting x86-64 functions");
    }
    let function_index: Int = 0;
    while (function_index < program.arena.functions.length()) {
        let function: WirFunction = program.arena.functions[function_index];
        if (reachable.functions[function_index] && function.linkage != WirLinkage.External) {
            let function_id: WirFuncID = WirFuncID(UInt32(function_index + 1));
            let lowered: X86LoweringResult = x86_lower_function_with_layouts(ref program, function_id, layouts, retain_function, release_function, null_function, bounds_function);
            if (lowered.errors.length() != 0) {
                return x86_module_error(lowered.errors[0]);
            }
            let offset: Int = output.bytes.length();
            let i: Int = 0;
            while (i < lowered.bytes.length()) {
                output.bytes.append(lowered.bytes[i]);
                i++;
            }

            codes.append(X86FunctionCode(function=function_id, offset=offset, bytes=lowered.bytes, calls=lowered.calls));
            symbols.append(X86Symbol(name=function.name, section=".text", offset=UInt32(offset), external=function.linkage == WirLinkage.Exported));
            i = 0;
            while (i < lowered.relocations.length()) {
                let relocation: X86Relocation = lowered.relocations[i];
                relocation.offset += UInt32(offset);
                relocations.append(relocation);
                i++;
            }
        }

        function_index++;
    }

    let code_index = 0;
    while (code_index < codes.length()) {
        let code: X86FunctionCode = codes[code_index];
        let call_index = 0;
        while (call_index < code.calls.length()) {
            let call: X86CallFixup = code.calls[call_index];
            let target_index: Int = wir_id_index(UInt32(call.target));
            if (target_index < 0 || target_index >= program.arena.functions.length()) {
                return x86_module_error("the x86_64 lowering could not resolve a call target");
            }

            let target: WirFunction = program.arena.functions[target_index];
            if (is_linux || target.linkage == WirLinkage.External) {
                let kind = X86RelocationKind.Rel32;
                if is_linux { kind = X86RelocationKind.Call32; }
                relocations.append(X86Relocation(section=".text", offset=UInt32(code.offset + call.offset), kind=kind, symbol=target.name, addend=0L));
            }
            call_index++;
        }
        code_index++;
    }

    function_index = 0;
    while (function_index < program.arena.functions.length()) {
        let function: WirFunction = program.arena.functions[function_index];
        if (reachable.functions[function_index] && function.linkage == WirLinkage.External) {
            let duplicate = false;
            let symbol_index = 0;
            while (symbol_index < symbols.length()) {
                if (symbols[symbol_index].name == function.name) { duplicate = true; }

                symbol_index++;
            }

            if (!duplicate) {
                if (x86_is_memop(function.name)) {
                    let offset: Int = output.bytes.length();
                    if (!x86_emit_memop(ref output, function.name)) {
                        return x86_module_error("cannot emit machine memory support");
                    }
                    symbols.append(X86Symbol(name=function.name, section=".text", offset=UInt32(offset), external=true));
                } else {
                    symbols.append(X86Symbol(name=function.name, section="", offset=0U, external=true));
                }
            }
        }

        function_index++;
    }
    if (!is_linux && !x86_patch_calls(ref program, ref output, codes)) {
        return x86_module_error("the x86_64 lowering could not resolve a direct call target");
    }
    let object: X86Object = X86Object(sections=[X86CodeSection(name=".text", bytes=output.bytes, alignment=16, executable=true, writable=false)], symbols=symbols, relocations=relocations);
    if verbose {
        print("Emitting global data");
    }
    let data_error: String = x86_emit_globals(ref program, layouts, reachable.globals, ref object);
    if (data_error.length() != 0) {
        return x86_module_error(data_error);
    }
    return X86ModuleResult(bytes=output.bytes, errors=[], relocations=object.relocations, symbols=object.symbols, sections=object.sections);
}
