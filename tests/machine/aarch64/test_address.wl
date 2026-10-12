// Test: AARCH64_ADDRESS
// File: tests/machine/aarch64/test_address.wl
// Focus: Lower struct field and scaled array addresses with the target data layout.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import verify_wir from "../../../src/compiler/wir/verify.wl"
import * from "../../../src/compiler/machine/aarch64/lowering.wl"


func main() -> Int {
    let program: WirModule = new_wir_module("aarch64-unknown-linux-gnu", 64);
    let i8: WirTypeID = wir_signed_int_type(ref program, 8);
    let i16: WirTypeID = wir_signed_int_type(ref program, 16);
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let i64: WirTypeID = wir_signed_int_type(ref program, 64);
    let pair: WirTypeID = wir_struct_type(ref program, [i8, i64]);
    let pair_pointer: WirTypeID = wir_pointer_type(ref program, pair);
    let i32_pointer: WirTypeID = wir_pointer_type(ref program, i32);
    let array: WirTypeID = wir_array_type(ref program, i16, 4UL);
    let array_pointer: WirTypeID = wir_pointer_type(ref program, array);

    let field_function: WirFuncID = wir_add_function(ref program, "second_field", [wir_param("pair", pair_pointer)], wir_pointer_type(ref program, i64), false, WirLinkage.Exported, WirABI.C);
    let field_block: WirBlockID = wir_add_block(ref program, field_function, "entry", []);
    let field_base: WirValueID = program.arena.functions[wir_id_index(UInt32(field_function))].parameters[0];
    let field_address: WirValueID = wir_field_address(ref program, field_block, field_base, 1, "field", no_wir_location());
    wir_return(ref program, field_block, field_address, no_wir_location());

    let index_function: WirFuncID = wir_add_function(ref program, "index_i32", [wir_param("base", i32_pointer), wir_param("index", i32)], i32_pointer, false, WirLinkage.Exported, WirABI.C);
    let index_block: WirBlockID = wir_add_block(ref program, index_function, "entry", []);
    let index_params: Vector(WirValueID) = program.arena.functions[wir_id_index(UInt32(index_function))].parameters;
    let index_address: WirValueID = wir_index_address(ref program, index_block, index_params[0], index_params[1], "element", no_wir_location());
    wir_return(ref program, index_block, index_address, no_wir_location());

    let array_function: WirFuncID = wir_add_function(ref program, "index_array", [wir_param("base", array_pointer), wir_param("index", i32)], wir_pointer_type(ref program, i16), false, WirLinkage.Exported, WirABI.C);
    let array_block: WirBlockID = wir_add_block(ref program, array_function, "entry", []);
    let array_params: Vector(WirValueID) = program.arena.functions[wir_id_index(UInt32(array_function))].parameters;
    let array_address: WirValueID = wir_index_address(ref program, array_block, array_params[0], array_params[1], "element", no_wir_location());
    wir_return(ref program, array_block, array_address, no_wir_location());

    let local_field_function: WirFuncID = wir_add_function(ref program, "local_field", [wir_param("value", i64)], i64, false, WirLinkage.Exported, WirABI.C);
    let local_field_block: WirBlockID = wir_add_block(ref program, local_field_function, "entry", []);
    let local_field_param: WirValueID = program.arena.functions[wir_id_index(UInt32(local_field_function))].parameters[0];
    let local_pair: WirValueID = wir_struct_value(ref program, local_field_block, pair, [wir_const_int(ref program, i8, UInt128(7U)), local_field_param], "pair", no_wir_location());
    let local_pair_slot: WirValueID = wir_stack_alloc(ref program, local_field_block, pair, "slot", no_wir_location());
    wir_store(ref program, local_field_block, local_pair, local_pair_slot, no_wir_location());
    let local_field_address: WirValueID = wir_field_address(ref program, local_field_block, local_pair_slot, 1, "field", no_wir_location());
    let local_field: WirValueID = wir_load(ref program, local_field_block, local_field_address, "value", no_wir_location());
    wir_return(ref program, local_field_block, local_field, no_wir_location());

    let local_array_function: WirFuncID = wir_add_function(ref program, "local_array", [wir_param("index", i32)], i16, false, WirLinkage.Exported, WirABI.C);
    let local_array_block: WirBlockID = wir_add_block(ref program, local_array_function, "entry", []);
    let local_array_index: WirValueID = program.arena.functions[wir_id_index(UInt32(local_array_function))].parameters[0];
    let local_array_value: WirValueID = wir_array_value(ref program, local_array_block, array, [
        wir_const_int(ref program, i16, UInt128(11U)),
        wir_const_int(ref program, i16, UInt128(22U)),
        wir_const_int(ref program, i16, UInt128(33U)),
        wir_const_int(ref program, i16, UInt128(44U))
    ], "array", no_wir_location());
    let local_array_slot: WirValueID = wir_stack_alloc(ref program, local_array_block, array, "slot", no_wir_location());
    wir_store(ref program, local_array_block, local_array_value, local_array_slot, no_wir_location());
    let local_array_address: WirValueID = wir_index_address(ref program, local_array_block, local_array_slot, local_array_index, "element", no_wir_location());
    let local_element: WirValueID = wir_load(ref program, local_array_block, local_array_address, "value", no_wir_location());
    wir_return(ref program, local_array_block, local_element, no_wir_location());

    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: invalid AArch64 address test: ", errors[0]);
        return 1;
    }

    let lowered: A64ModuleResult = a64_lower_module(ref program);
    if (lowered.errors.length() != 0) {
        print("FAIL: AArch64 aggregate addressing: ", lowered.errors[0]);
        return 1;
    }
    if (lowered.symbols.length() != 5 || lowered.sections.length() == 0 || lowered.sections[0].bytes.length() == 0) {
        print("FAIL: missing AArch64 aggregate address code");
        return 1;
    }

    print("PASS: AArch64 aggregate addresses");
    return 0;
}
