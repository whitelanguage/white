// Test: AARCH64_FLOAT
// File: tests/machine/aarch64/test_float.wl
// Focus: Lower scalar floating-point arithmetic and the AAPCS64 register ABI.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/machine/aarch64/lowering.wl"


func main() -> Int {
    let program: WirModule = new_wir_module("aarch64-unknown-linux-gnu", 64);
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let f64: WirTypeID = wir_float_type(ref program, 64);
    let function_id: WirFuncID = wir_add_function(
        ref program,
        "float_math",
        [wir_param("integer", i32), wir_param("left", f64), wir_param("right", f64)],
        f64,
        false,
        WirLinkage.Exported,
        WirABI.C
    );
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let sum: WirValueID = wir_binary(ref program, entry, WirOpcode.Add, f64, function.parameters[1], function.parameters[2], "sum", no_wir_location());
    let product: WirValueID = wir_binary(ref program, entry, WirOpcode.Multiply, f64, sum, wir_const_float(ref program, f64, 2.0), "product", no_wir_location());
    let quotient: WirValueID = wir_binary(ref program, entry, WirOpcode.FloatDivide, f64, product, wir_const_float(ref program, f64, 4.0), "quotient", no_wir_location());
    let negative: WirValueID = wir_unary(ref program, entry, WirOpcode.FloatNegate, f64, quotient, "negative", no_wir_location());
    wir_return(ref program, entry, negative, no_wir_location());

    let lowered: A64LoweringResult = a64_lower_function(ref program, function_id);
    if (lowered.errors.length() != 0) {
        print("FAIL: AArch64 floating-point lowering failed: ", lowered.errors[0]);
        return 1;
    }
    if (lowered.bytes.length() < 48 || lowered.bytes.length() % 4 != 0) {
        print("FAIL: unexpected AArch64 floating-point function size: ", lowered.bytes.length());
        return 1;
    }

    let compare_id: WirFuncID = wir_add_function(ref program, "float_less", [wir_param("left", f64), wir_param("right", f64)], program.bool_type, false, WirLinkage.Exported, WirABI.C);
    let compare_entry: WirBlockID = wir_add_block(ref program, compare_id, "entry", []);
    let compare: WirFunction = program.arena.functions[wir_id_index(UInt32(compare_id))];
    let less: WirValueID = wir_binary(ref program, compare_entry, WirOpcode.FloatLess, program.bool_type, compare.parameters[0], compare.parameters[1], "less", no_wir_location());
    wir_return(ref program, compare_entry, less, no_wir_location());

    let comparison: A64LoweringResult = a64_lower_function(ref program, compare_id);
    if (comparison.errors.length() != 0) {
        print("FAIL: AArch64 floating-point comparison failed: ", comparison.errors[0]);
        return 1;
    }

    let f32: WirTypeID = wir_float_type(ref program, 32);
    let scalar_id: WirFuncID = wir_add_function(ref program, "float32_add", [wir_param("left", f32), wir_param("right", f32)], f32, false, WirLinkage.Exported, WirABI.C);
    let scalar_entry: WirBlockID = wir_add_block(ref program, scalar_id, "entry", []);
    let scalar: WirFunction = program.arena.functions[wir_id_index(UInt32(scalar_id))];
    let scalar_sum: WirValueID = wir_binary(ref program, scalar_entry, WirOpcode.Add, f32, scalar.parameters[0], scalar.parameters[1], "sum", no_wir_location());
    wir_return(ref program, scalar_entry, scalar_sum, no_wir_location());
    let scalar_lowered: A64LoweringResult = a64_lower_function(ref program, scalar_id);
    if (scalar_lowered.errors.length() != 0) {
        print("FAIL: AArch64 f32 lowering failed: ", scalar_lowered.errors[0]);
        return 1;
    }

    let convert_id: WirFuncID = wir_add_function(ref program, "float_convert", [wir_param("value", f64), wir_param("integer", i32)], i32, false, WirLinkage.Exported, WirABI.C);
    let convert_entry: WirBlockID = wir_add_block(ref program, convert_id, "entry", []);
    let convert: WirFunction = program.arena.functions[wir_id_index(UInt32(convert_id))];
    let narrowed: WirValueID = wir_cast(ref program, convert_entry, convert.parameters[0], f32, "narrowed", no_wir_location());
    let widened: WirValueID = wir_cast(ref program, convert_entry, narrowed, f64, "widened", no_wir_location());
    let from_integer: WirValueID = wir_cast(ref program, convert_entry, convert.parameters[1], f64, "float", no_wir_location());
    let sum_convert: WirValueID = wir_binary(ref program, convert_entry, WirOpcode.Add, f64, widened, from_integer, "sum", no_wir_location());
    let converted: WirValueID = wir_cast(ref program, convert_entry, sum_convert, i32, "integer", no_wir_location());
    wir_return(ref program, convert_entry, converted, no_wir_location());

    let convert_lowered: A64LoweringResult = a64_lower_function(ref program, convert_id);
    if (convert_lowered.errors.length() != 0) {
        print("FAIL: AArch64 numeric conversion failed: ", convert_lowered.errors[0]);
        return 1;
    }

    print("PASS: AArch64 floating-point lowering");
    return 0;
}
