// Test: AARCH64_EXTERNAL_CALL
// File: tests/machine/aarch64/test_external_call.wl
// Focus: Keep undefined C functions in the ELF symbol table for CALL26 relocations.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/machine/aarch64/model.wl"
import * from "../../../src/compiler/machine/aarch64/lowering.wl"
import a64_lower_module from "../../../src/compiler/machine/aarch64/module.wl"
import a64_elf_object from "../../../src/compiler/machine/aarch64/elf.wl"


func main() -> Int {
    let program: WirModule = new_wir_module("aarch64-unknown-linux-gnu", 64);
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let abs_id: WirFuncID = wir_add_function(ref program, "abs", [wir_param("value", int_type)], int_type, false, WirLinkage.External, WirABI.C);
    let caller_id: WirFuncID = wir_add_function(ref program, "external_abs", [], int_type, false, WirLinkage.Exported, WirABI.C);
    let entry: WirBlockID = wir_add_block(ref program, caller_id, "entry", []);
    let value: WirValueID = wir_const_int(ref program, int_type, UInt128(4294967254U));
    let result: WirValueID = wir_call(ref program, entry, program.arena.functions[wir_id_index(UInt32(abs_id))].address, [value], "result", no_wir_location());
    wir_return(ref program, entry, result, no_wir_location());

    let lowered: A64ModuleResult = a64_lower_module(ref program);
    if (lowered.errors.length() != 0) {
        print("FAIL: AArch64 external call lowering failed: ", lowered.errors[0]);
        return 1;
    }

    let found: Bool = false;
    let i: Int = 0;
    while (i < lowered.symbols.length()) {
        if (lowered.symbols[i].name == "abs" && lowered.symbols[i].section.length() == 0) { found = true; }
        i++;
    }
    if (!found) {
        print("FAIL: undefined AArch64 function symbol was dropped");
        return 1;
    }

    a64_elf_object(A64Object(sections=lowered.sections, symbols=lowered.symbols, relocations=lowered.relocations))?;
    catch(err) {
        print("FAIL: AArch64 external call object could not be encoded");
        return 1;
    }

    print("PASS: AArch64 external call relocation");
    return 0;
}
