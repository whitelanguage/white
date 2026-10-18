// Test: AARCH64_STACK_SLOTS
// File: tests/machine/aarch64/test_stack.wl
// Focus: Lower scalar stack allocation, store and load with a balanced frame.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/machine/aarch64/lowering.wl"
import A64LoweringResult from "../../../src/compiler/machine/aarch64/model.wl"


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

    let byte_type: WirTypeID = wir_unsigned_int_type(ref program, 8);
    let large_array: WirTypeID = wir_array_type(ref program, byte_type, UIntSize(8192));
    let large_id: WirFuncID = wir_add_function(ref program, "large_stack", [], int_type, false, WirLinkage.Exported, WirABI.C);
    let large_entry: WirBlockID = wir_add_block(ref program, large_id, "entry", []);
    let large_slot: WirValueID = wir_stack_alloc(ref program, large_entry, large_array, "buffer", no_wir_location());
    let large_pointer: WirTypeID = program.arena.values[wir_id_index(UInt32(large_slot))].type_id;
    let pointer_slot: WirValueID = wir_stack_alloc(ref program, large_entry, large_pointer, "pointer", no_wir_location());
    wir_store(ref program, large_entry, large_slot, pointer_slot, no_wir_location());
    wir_load(ref program, large_entry, pointer_slot, "loaded.pointer", no_wir_location());
    wir_return(ref program, large_entry, wir_const_int(ref program, int_type, UInt128(0U)), no_wir_location());

    let large: A64LoweringResult = a64_lower_function(ref program, large_id);
    if (large.errors.length() != 0) {
        print("FAIL: AArch64 large stack lowering failed: ", large.errors[0]);
        return 1;
    }

    print("PASS: AArch64 scalar stack slots");
    return 0;
}
