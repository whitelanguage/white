// Test: AARCH64_AGGREGATE
// File: tests/machine/aarch64/test_aggregate.wl
// Focus: Build, copy, and extract stack-resident structs and arrays without exposing padding bytes.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import verify_wir from "../../../src/compiler/wir/verify.wl"
import * from "../../../src/compiler/machine/aarch64/lowering.wl"


func main() -> Int {
    let program: WirModule = new_wir_module("aarch64-unknown-linux-gnu", 64);
    let i8: WirTypeID = wir_signed_int_type(ref program, 8);
    let i16: WirTypeID = wir_signed_int_type(ref program, 16);
    let i64: WirTypeID = wir_signed_int_type(ref program, 64);
    let pair: WirTypeID = wir_struct_type(ref program, [i8, i64]);
    let array: WirTypeID = wir_array_type(ref program, i16, 3UL);

    let field_function: WirFuncID = wir_add_function(ref program, "build_field", [wir_param("first", i8), wir_param("second", i64)], i64, false, WirLinkage.Exported, WirABI.C);
    let field_block: WirBlockID = wir_add_block(ref program, field_function, "entry", []);
    let field_params: Vector(WirValueID) = program.arena.functions[wir_id_index(UInt32(field_function))].parameters;
    let pair_value: WirValueID = wir_struct_value(ref program, field_block, pair, [field_params[0], field_params[1]], "pair", no_wir_location());
    let second: WirValueID = wir_field(ref program, field_block, pair_value, 1, "second", no_wir_location());
    wir_return(ref program, field_block, second, no_wir_location());

    let array_function: WirFuncID = wir_add_function(ref program, "build_array", [wir_param("first", i16), wir_param("second", i16), wir_param("third", i16)], i16, false, WirLinkage.Exported, WirABI.C);
    let array_block: WirBlockID = wir_add_block(ref program, array_function, "entry", []);
    let array_params: Vector(WirValueID) = program.arena.functions[wir_id_index(UInt32(array_function))].parameters;
    let array_value: WirValueID = wir_array_value(ref program, array_block, array, array_params, "array", no_wir_location());
    let index: WirValueID = wir_const_int(ref program, wir_unsigned_int_type(ref program, 32), UInt128(1U));
    let element: WirValueID = wir_index(ref program, array_block, array_value, index, "element", no_wir_location());
    wir_return(ref program, array_block, element, no_wir_location());

    let copy_function: WirFuncID = wir_add_function(ref program, "copy_field", [wir_param("value", i64)], i64, false, WirLinkage.Exported, WirABI.C);
    let copy_block: WirBlockID = wir_add_block(ref program, copy_function, "entry", []);
    let copy_param: WirValueID = program.arena.functions[wir_id_index(UInt32(copy_function))].parameters[0];
    let original: WirValueID = wir_struct_value(ref program, copy_block, pair, [wir_const_int(ref program, i8, UInt128(9U)), copy_param], "original", no_wir_location());
    let slot: WirValueID = wir_stack_alloc(ref program, copy_block, pair, "slot", no_wir_location());
    wir_store(ref program, copy_block, original, slot, no_wir_location());
    let copy: WirValueID = wir_load(ref program, copy_block, slot, "copy", no_wir_location());
    let copied_field: WirValueID = wir_field(ref program, copy_block, copy, 1, "field", no_wir_location());
    wir_return(ref program, copy_block, copied_field, no_wir_location());

    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: invalid AArch64 aggregate test: ", errors[0]);
        return 1;
    }

    let lowered: A64ModuleResult = a64_lower_module(ref program);
    if (lowered.errors.length() != 0) {
        print("FAIL: AArch64 aggregate lowering: ", lowered.errors[0]);
        return 1;
    }
    if (lowered.symbols.length() != 3 || lowered.sections.length() == 0 || lowered.sections[0].bytes.length() == 0) {
        print("FAIL: missing AArch64 aggregate code");
        return 1;
    }

    print("PASS: AArch64 aggregate values");
    return 0;
}
