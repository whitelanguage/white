// src/compiler/machine/aarch64/module.wl
import * from "model.wl"
import * from "../../wir/model.wl"
import * from "encoder.wl"
import * from "allocator.wl"
import * from "memory.wl"
import * from "abi.wl"
import * from "fp.wl"
import WirReachability, wir_reachable_symbols from "../../wir/deadcode.wl"
import wir_type_layouts from "../../wir/layout.wl"
import MachineSection, MachineSymbol from "../object.wl"
import MachineDataResult, MachineDataRelocation, machine_emit_globals from "../data.wl"
import * from "lowering.wl"
import machine_lower_remainders from "../remainder.wl"


func a64_module_error(message: String) -> A64ModuleResult {
    return A64ModuleResult(errors=[message], sections=[], symbols=[], relocations=[]);
}

func a64_lower_module(ref program: WirModule) -> A64ModuleResult {
// legalization finishes the type table before functions share its layouts
    if (program.target != "aarch64-unknown-linux-gnu" || program.pointer_bits != 64) {
        return a64_module_error("the AArch64 machine backend does not support this target");
    }
    let rem_error = machine_lower_remainders(ref program);
    if (rem_error.length() != 0) { return a64_module_error(rem_error); }
    let layouts: Vector(WirTypeLayout) = wir_type_layouts(program);

    let text: Vector(Byte) = [];
    let symbols: Vector(A64Symbol) = [];
    let relocations: Vector(A64Relocation) = [];
    let reachable: WirReachability = wir_reachable_symbols(program);
    let i: Int = 0;

    while (i < program.arena.functions.length()) {
        let function: WirFunction = program.arena.functions[i];
        if (reachable.functions[i] && function.blocks.length() != 0) {
            let offset: Int = text.length();
            let lowered: A64LoweringResult = a64_lower_function_with_layouts(ref program, WirFuncID(UInt32(i + 1)), layouts);
            if (lowered.errors.length() != 0) {
                return a64_module_error("in function '" + function.name + "': " + lowered.errors[0]);
            }

            let byte_index: Int = 0;
            while (byte_index < lowered.bytes.length()) {
                text.append(lowered.bytes[byte_index]);
                byte_index++;
            }
            let relocation_index: Int = 0;
            while (relocation_index < lowered.relocations.length()) {
                let relocation: A64Relocation = lowered.relocations[relocation_index];
                relocation.offset += UInt32(offset);
                relocations.append(relocation);
                relocation_index++;
            }
            symbols.append(A64Symbol(name=function.name, section=".text", offset=UInt32(offset), external=function.linkage == WirLinkage.Exported, hidden=function.linkage != WirLinkage.Exported));
        } else if (reachable.functions[i] && function.linkage == WirLinkage.External) {
            symbols.append(A64Symbol(name=function.name, section="", offset=0U, external=true, hidden=false));
        }
        i++;
    }

    let data: MachineDataResult = machine_emit_globals(ref program, layouts, ".data.rel.ro", true, reachable.globals);
    if (data.message.length() != 0) { return a64_module_error(data.message); }

    i = 0;
    while (i < data.symbols.length()) {
        let symbol: MachineSymbol = data.symbols[i];
        symbols.append(A64Symbol(name=symbol.name, section=symbol.section, offset=symbol.offset, external=symbol.external, hidden=symbol.hidden));
        i++;
    }
    i = 0;
    while (i < data.relocations.length()) {
        let relocation: MachineDataRelocation = data.relocations[i];
        relocations.append(A64Relocation(section=relocation.section, offset=relocation.offset, kind=A64RelocationKind.Abs64, symbol=relocation.symbol, addend=relocation.addend));
        i++;
    }

    let sections: Vector(A64Section) = [A64Section(name=".text", bytes=text, alignment=4, executable=true, writable=false)];
    i = 0;
    while (i < data.sections.length()) {
        let section: MachineSection = data.sections[i];
        sections.append(A64Section(name=section.name, bytes=section.bytes, alignment=section.alignment, executable=section.executable, writable=section.writable));
        i++;
    }

    return A64ModuleResult(
        errors=[],
        sections=sections,
        symbols=symbols,
        relocations=relocations
    );
}
