// Test: X86_64_STACK_REUSE
// File: tests/machine/x86_64/test_stack_reuse.wl
// Focus: Reusing stack homes for short-lived aggregate values.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/machine/x86_64/lowering.wl"

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i64: WirTypeID = wir_signed_int_type(ref program, 64);
    let record: WirTypeID = wir_struct_type(ref program, [i64, i64, i64, i64]);
    let function: WirFuncID = wir_add_function(ref program, "reuse", [], i64, false, WirLinkage.Internal, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, function, "entry", []);
    let zero: WirValueID = wir_const_int(ref program, i64, UInt128(0U));
    let result: WirValueID = zero;
    let i = 0;
    while (i < 256) {
        let value: WirValueID = wir_const_int(ref program, i64, UInt128(UInt64(i)));
        let aggregate: WirValueID = wir_struct_value(ref program, entry, record, [value, zero, zero, zero], "record", no_wir_location());
        result = wir_field(ref program, entry, aggregate, 0, "field", no_wir_location());
        i++;
    }
    wir_return(ref program, entry, result, no_wir_location());

    let current: WirFunction = program.arena.functions[wir_id_index(UInt32(function))];
    let order: Vector(WirBlockID) = x86_block_order(current);
    let layouts: Vector(WirTypeLayout) = x86_type_layouts(ref program);
    let cross: X86ValueFlags = x86_cross_block_values(ref program, order);
    let slots: Vector(X86StackSlot) = x86_collect_stack_slots(ref program, current, order, false, cross, layouts);
    if (x86_stack_slots_end(slots) > 64) {
        print("FAIL: short-lived aggregate stack homes were not reused");
        return 1;
    }

    let lowered: X86LoweringResult = x86_lower_function(ref program, function);
    if (lowered.errors.length() != 0) {
        print("FAIL: stack reuse lowering: ", lowered.errors[0]);
        return 1;
    }

    print("PASS: x86_64 aggregate stack reuse");
    return 0;
}
