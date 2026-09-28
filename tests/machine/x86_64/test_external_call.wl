// Test: X86_64_EXTERNAL_CALL
// File: tests/machine/x86_64/test_external_call.wl
// Focus: Emit a COFF REL32 relocation for an external function call.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/print.wl"
import * from "../../../src/compiler/machine/x86_64/model.wl"
import * from "../../../src/compiler/machine/x86_64/lowering.wl"
import * from "../../../src/compiler/machine/x86_64/coff.wl"

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let main_id: WirFuncID = wir_add_function(ref program, "main", [], int_type, false, WirLinkage.Exported, WirABI.White);
    let main_entry: WirBlockID = wir_add_block(ref program, main_id, "entry", []);
    let host_id: WirFuncID = wir_add_function(ref program, "host_value", [], int_type, false, WirLinkage.External, WirABI.C);
    let host_address: WirValueID = program.arena.functions[wir_id_index(UInt32(host_id))].address;
    let value: WirValueID = wir_call(ref program, main_entry, host_address, [], "value", no_wir_location());
    wir_return(ref program, main_entry, value, no_wir_location());

    let caller_params: Vector(WirParam) = [WirParam(name="input", type_id=int_type)];
    let caller_id: WirFuncID = wir_add_function(ref program, "caller", caller_params, int_type, false, WirLinkage.Exported, WirABI.White);
    let caller_entry: WirBlockID = wir_add_block(ref program, caller_id, "entry", []);
    let caller_value: WirValueID = wir_call(ref program, caller_entry, host_address, [], "value", no_wir_location());
    let caller_sum: WirValueID = wir_binary(ref program, caller_entry, WirOpcode.Add, int_type, program.arena.functions[wir_id_index(UInt32(caller_id))].parameters[0], caller_value, "sum", no_wir_location());
    wir_return(ref program, caller_entry, caller_sum, no_wir_location());

    let lowered: X86ModuleResult = x86_lower_module(program);
    if (lowered.errors.length() != 0 || lowered.relocations.length() != 2 || lowered.symbols.length() != 3) {
        print("FAIL: external call relocation was not produced");
        return 1;
    }
    if (lowered.symbols[0].name != "main" || lowered.symbols[0].section != ".text" || lowered.symbols[0].offset != 0U ||
        lowered.symbols[1].name != "caller" || lowered.symbols[1].section != ".text" || lowered.symbols[1].offset == 0U ||
        lowered.symbols[2].name != "host_value" || lowered.symbols[2].section != "") {
        print("FAIL: module symbols were not collected");
        return 1;
    }
    let object: Vector(Byte) = coff_object_for_text_symbols(lowered.bytes, lowered.symbols, lowered.relocations)?;
    catch(err) {
        print("FAIL: could not write external call object");
        return 1;
    }
    let relocation: X86Relocation = lowered.relocations[0];
    if (relocation.symbol != "host_value" || relocation.kind != X86RelocationKind.Rel32) {
        print("FAIL: external relocation has the wrong symbol or kind");
        return 1;
    }
    print("PASS: x86_64 external call relocation");
    print("OBJECT-BEGIN");
    let i: Int = 0;
    while (i < object.length()) {
        print(Int(object[i]));
        i += 1;
    }
    print("OBJECT-END");
    return 0;
}
