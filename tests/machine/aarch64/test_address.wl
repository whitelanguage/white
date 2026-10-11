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
    if (lowered.symbols.length() != 3 || lowered.sections.length() == 0 || lowered.sections[0].bytes.length() == 0) {
        print("FAIL: missing AArch64 aggregate address code");
        return 1;
    }

    print("PASS: AArch64 aggregate addresses");
    return 0;
}
