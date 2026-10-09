// Test: AARCH64_FLOAT_CALLS
// File: tests/machine/aarch64/test_float_calls.wl
// Focus: Keep integer and floating argument banks separate across a direct call.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/machine/aarch64/model.wl"
import * from "../../../src/compiler/machine/aarch64/lowering.wl"


func main() -> Int {
    let program: WirModule = new_wir_module("aarch64-unknown-linux-gnu", 64);
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let f64: WirTypeID = wir_float_type(ref program, 64);
    let helper_id: WirFuncID = wir_add_function(ref program, "float_helper", [wir_param("left", f64), wir_param("right", f64)], f64, false, WirLinkage.Internal, WirABI.C);
    let helper_entry: WirBlockID = wir_add_block(ref program, helper_id, "entry", []);
    let helper: WirFunction = program.arena.functions[wir_id_index(UInt32(helper_id))];
    let sum: WirValueID = wir_binary(ref program, helper_entry, WirOpcode.Add, f64, helper.parameters[0], helper.parameters[1], "sum", no_wir_location());
    wir_return(ref program, helper_entry, sum, no_wir_location());

    let caller_id: WirFuncID = wir_add_function(ref program, "float_caller", [wir_param("tag", i32), wir_param("left", f64), wir_param("right", f64)], f64, false, WirLinkage.Exported, WirABI.C);
    let caller_entry: WirBlockID = wir_add_block(ref program, caller_id, "entry", []);
    let caller: WirFunction = program.arena.functions[wir_id_index(UInt32(caller_id))];
    let result: WirValueID = wir_call(ref program, caller_entry, program.arena.functions[wir_id_index(UInt32(helper_id))].address, [caller.parameters[1], caller.parameters[2]], "result", no_wir_location());
    wir_return(ref program, caller_entry, result, no_wir_location());

    let lowered: A64ModuleResult = a64_lower_module(ref program);
    if (lowered.errors.length() != 0) {
        print("FAIL: AArch64 floating call lowering failed: ", lowered.errors[0]);
        return 1;
    }
    if (lowered.relocations.length() != 1 || lowered.relocations[0].kind != A64RelocationKind.Call26 ||
        lowered.relocations[0].symbol != "float_helper") {
        print("FAIL: AArch64 floating call relocation is missing");
        return 1;
    }

    print("PASS: AArch64 floating calls");
    return 0;
}
