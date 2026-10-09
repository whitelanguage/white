// Test: AARCH64_STACK_SLOTS
// File: tests/machine/aarch64/test_stack.wl
// Focus: Lower scalar stack allocation, store and load with a balanced frame.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/machine/aarch64/lowering.wl"


func main() -> Int {
    let program: WirModule = new_wir_module("aarch64-unknown-linux-gnu", 64);
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let function_id: WirFuncID = wir_add_function(ref program, "stack_value", [], int_type, false, WirLinkage.Exported, WirABI.C);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let slot: WirValueID = wir_stack_alloc(ref program, entry, int_type, "slot", no_wir_location());

    wir_store(ref program, entry, wir_const_int(ref program, int_type, UInt128(42U)), slot, no_wir_location());
    let loaded: WirValueID = wir_load(ref program, entry, slot, "loaded", no_wir_location());
    wir_return(ref program, entry, loaded, no_wir_location());

    let lowered: A64LoweringResult = a64_lower_function(ref program, function_id);
    if (lowered.errors.length() != 0) {
        print("FAIL: AArch64 stack lowering failed: ", lowered.errors[0]);
        return 1;
    }
    if (lowered.bytes.length() < 40 || lowered.bytes.length() % 4 != 0) {
        print("FAIL: unexpected AArch64 stack function size: ", lowered.bytes.length());
        return 1;
    }

    print("PASS: AArch64 scalar stack slots");
    return 0;
}
