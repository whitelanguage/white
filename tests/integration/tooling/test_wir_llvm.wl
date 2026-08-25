// Test: WIR_LLVM_BACKEND
// File: tests/integration/tooling/test_wir_llvm.wl
// Focus: Emitting executable LLVM IR from verified scalar WIR.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/backend/llvm.wl"

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let add_id: WirFuncID = wir_add_function(ref program, "add", [wir_param("a", i32_type), wir_param("b", i32_type)], i32_type, false, WirLinkage.Internal, WirABI.White);
    let add_entry: WirBlockID = wir_add_block(ref program, add_id, "entry", []);
    let add_function: WirFunction = program.arena.functions[wir_id_index(UInt32(add_id))];
    let sum: WirValueID = wir_binary(ref program, add_entry, WirOpcode.Add, i32_type, add_function.parameters[0], add_function.parameters[1], "sum", no_wir_location());
    wir_return(ref program, add_entry, sum, no_wir_location());

    let f64_type: WirTypeID = wir_float_type(ref program, 64);
    let float_id: WirFuncID = wir_add_function(ref program, "float_equal", [wir_param("a", f64_type), wir_param("b", f64_type)], program.bool_type, false, WirLinkage.Internal, WirABI.White);
    let float_entry: WirBlockID = wir_add_block(ref program, float_id, "entry", []);
    let float_function: WirFunction = program.arena.functions[wir_id_index(UInt32(float_id))];
    let float_sum: WirValueID = wir_binary(ref program, float_entry, WirOpcode.Add, f64_type, float_function.parameters[0], float_function.parameters[1], "sum", no_wir_location());
    let equal: WirValueID = wir_binary(ref program, float_entry, WirOpcode.Equal, program.bool_type, float_sum, float_function.parameters[1], "equal", no_wir_location());
    wir_binary(ref program, float_entry, WirOpcode.NotEqual, program.bool_type, float_sum, float_function.parameters[1], "not_equal", no_wir_location());
    wir_return(ref program, float_entry, equal, no_wir_location());

    let main_id: WirFuncID = wir_add_function(ref program, "main", [], i32_type, false, WirLinkage.Exported, WirABI.White);
    let main_entry: WirBlockID = wir_add_block(ref program, main_id, "entry", []);
    let result: WirValueID = wir_call(ref program, main_entry, add_function.address, [wir_const_int(ref program, i32_type, UInt128(40U)), wir_const_int(ref program, i32_type, UInt128(2U))], "result", no_wir_location());
    wir_return(ref program, main_entry, result, no_wir_location());
    let emitted: WirLLVMResult = emit_wir_llvm(program)?;
    catch(err) { print("FAIL: LLVM emission failed"); return 1; }
    if (emitted.errors.length() != 0) { print("FAIL: valid scalar WIR was rejected: ", emitted.errors[0]); return 1; }
    let expected: String = "target triple = \"x86_64-pc-windows-msvc\"\n\ndefine internal i32 @add(i32 %v1, i32 %v2) {\nb1:\n  %v4 = add i32 %v1, %v2\n  ret i32 %v4\n}\n\ndefine internal i1 @float_equal(double %v5, double %v6) {\nb2:\n  %v8 = fadd double %v5, %v6\n  %v9 = fcmp oeq double %v8, %v6\n  %v10 = fcmp une double %v8, %v6\n  ret i1 %v9\n}\n\ndefine i32 @main() {\nb3:\n  %v14 = call i32 @add(i32 40, i32 2)\n  ret i32 %v14\n}\n";
    if (emitted.text != expected) { print("FAIL: LLVM backend output is not stable"); print(emitted.text); return 1; }
    print("PASS: WIR LLVM backend");
    return 0;
}
