// Test: WIR_LLVM_NATIVE_SHAPES
// File: tests/integration/tooling/test_wir_llvm_native_shapes.wl
// Focus: physical aggregate classes and register exhaustion across native ABIs.
import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/abi/llvm.wl"


func check(target: String) -> Bool {
    let program = new_wir_module(target, 64);
    let i8 = wir_signed_int_type(ref program, 8);
    let i32 = wir_signed_int_type(ref program, 32);
    let i128 = wir_signed_int_type(ref program, 128);
    let f32 = wir_float_type(ref program, 32);
    let f64 = wir_float_type(ref program, 64);
    let floats = wir_struct_type(ref program, [f32, f32, f32]);
    let ints = wir_struct_type(ref program, [i32, i32, i32]);
    let mixed = wir_struct_type(ref program, [f32, wir_signed_int_type(ref program, 64)]);
    let sig = wir_function_type(ref program, [i32, i32, i32, i32, i32, ints, i32], floats, false, WirABI.C);
    let plan = native_llvm_plan(program, program.arena.types[wir_id_index(UInt32(sig))]);
    let empty = wir_struct_type(ref program, []);
    let empty_sig = wir_function_type(ref program, [empty], empty, false, WirABI.C);
    let empty_plan = native_llvm_plan(program, program.arena.types[wir_id_index(UInt32(empty_sig))]);
    if (empty_plan.result.mode != 0 || empty_plan.params[0].mode != 0) { return false; }
    if (target.starts_with("x86_64-unknown-linux")) {
        if (plan.result.physical != "{ <2 x float>, float }" || plan.params[5].mode != -2) { return false; }
        let fp_sig = wir_function_type(ref program, [f64, f64, f64, f64, f64, f64, f64, f64, mixed, i32], mixed, false, WirABI.C);
        let fp_plan = native_llvm_plan(program, program.arena.types[wir_id_index(UInt32(fp_sig))]);
        if (fp_plan.params[8].mode != -2 || fp_plan.result.physical != "{ float, i64 }") { return false; }
        let narrow = wir_function_type(ref program, [i8], i8, false, WirABI.C);
        let narrow_plan = native_llvm_plan(program, program.arena.types[wir_id_index(UInt32(narrow))]);
        if (narrow_plan.params[0].attr != "signext" || narrow_plan.result.attr != "signext") { return false; }
    } else if (target.starts_with("aarch64-")) {
        if (plan.result.physical != "[3 x float]" || plan.params[5].physical != "[2 x i64]") { return false; }
    } else {
        let wide = wir_function_type(ref program, [i128], i128, false, WirABI.C);
        let wide_plan = native_llvm_plan(program, program.arena.types[wir_id_index(UInt32(wide))]);
        if (wide_plan.params[0].mode != -1 || wide_plan.result.physical != "<2 x i64>") { return false; }
    }
    return true;
}

func main() -> Int {
    if (!check("x86_64-unknown-linux-gnu") || !check("aarch64-unknown-linux-gnu") || !check("x86_64-pc-windows-msvc")) { return 1; }
    print("PASS: native LLVM signature plans");
    return 0;
}
