// Test: AARCH64_CONTROL_FLOW
// File: tests/machine/aarch64/test_control.wl
// Focus: Encode integer comparisons and patch forward AArch64 branches.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/machine/aarch64/model.wl"
import * from "../../../src/compiler/machine/aarch64/lowering.wl"
import a64_lower_module from "../../../src/compiler/machine/aarch64/module.wl"
import a64_elf_object from "../../../src/compiler/machine/aarch64/elf.wl"


func main() -> Int {
    let program: WirModule = new_wir_module("aarch64-unknown-linux-gnu", 64);
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let function_id: WirFuncID = wir_add_function(
        ref program,
        "choose",
        [wir_param("left", int_type), wir_param("right", int_type)],
        int_type,
        false,
        WirLinkage.Exported,
        WirABI.C
    );
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let less: WirBlockID = wir_add_block(ref program, function_id, "less", []);
    let otherwise: WirBlockID = wir_add_block(ref program, function_id, "otherwise", []);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];

    let condition: WirValueID = wir_binary(
        ref program,
        entry,
        WirOpcode.SignedLess,
        program.bool_type,
        function.parameters[0],
        function.parameters[1],
        "condition",
        no_wir_location()
    );
    wir_append(
        ref program,
        entry,
        WirOpcode.Branch,
        program.void_type,
        [condition],
        [wir_edge(less, []), wir_edge(otherwise, [])],
        no_wir_location()
    );
    wir_return(ref program, less, wir_const_int(ref program, int_type, UInt128(42U)), no_wir_location());
    wir_return(ref program, otherwise, wir_const_int(ref program, int_type, UInt128(1U)), no_wir_location());

    let lowered: A64ModuleResult = a64_lower_module(ref program);
    if (lowered.errors.length() != 0) {
        print("FAIL: AArch64 control-flow lowering failed: ", lowered.errors[0]);
        return 1;
    }
    if (lowered.sections.length() != 1 || lowered.sections[0].bytes.length() < 28) {
        print("FAIL: AArch64 control-flow code was not emitted");
        return 1;
    }

    a64_elf_object(A64Object(sections=lowered.sections, symbols=lowered.symbols, relocations=lowered.relocations))?;
    catch(err) {
        print("FAIL: AArch64 control-flow object could not be encoded");
        return 1;
    }

    print("PASS: AArch64 control-flow lowering");
    return 0;
}
