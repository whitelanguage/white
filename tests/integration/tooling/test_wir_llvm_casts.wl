// Test: WIR_LLVM_CASTS
// File: tests/integration/tooling/test_wir_llvm_casts.wl
// Focus: Emitting checked numeric conversions without inventing runtime casts.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/backend/llvm.wl"

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let u32_type: WirTypeID = wir_unsigned_int_type(ref program, 32);
    let i64_type: WirTypeID = wir_signed_int_type(ref program, 64);
    let f64_type: WirTypeID = wir_float_type(ref program, 64);
    let function_id: WirFuncID = wir_add_function(ref program, "casts", [wir_param("signed", i32_type), wir_param("unsigned", u32_type), wir_param("wide", i64_type), wir_param("float", f64_type)], i64_type, false, WirLinkage.Internal, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let signed_wide: WirValueID = wir_cast(ref program, entry, function.parameters[0], i64_type, "signed_wide", no_wir_location());
    let unsigned_wide: WirValueID = wir_cast(ref program, entry, function.parameters[1], i64_type, "unsigned_wide", no_wir_location());
    wir_cast(ref program, entry, function.parameters[2], i32_type, "narrow", no_wir_location());
    wir_cast(ref program, entry, function.parameters[0], f64_type, "as_float", no_wir_location());
    let float_integer: WirValueID = wir_cast(ref program, entry, function.parameters[3], i64_type, "float_integer", no_wir_location());
    let unsigned_view: WirValueID = wir_cast(ref program, entry, function.parameters[0], u32_type, "unsigned_view", no_wir_location());
    let view_wide: WirValueID = wir_cast(ref program, entry, unsigned_view, i64_type, "view_wide", no_wir_location());
    let first: WirValueID = wir_binary(ref program, entry, WirOpcode.Add, i64_type, signed_wide, unsigned_wide, "first", no_wir_location());
    let second: WirValueID = wir_binary(ref program, entry, WirOpcode.Add, i64_type, first, float_integer, "second", no_wir_location());
    let result: WirValueID = wir_binary(ref program, entry, WirOpcode.Add, i64_type, second, view_wide, "result", no_wir_location());
    wir_return(ref program, entry, result, no_wir_location());

    let emitted: WirLLVMResult = emit_wir_llvm(program)?;
    catch(err) {
        print("FAIL: WIR numeric casts could not be emitted as LLVM IR");
        return 1;
    }
    if (emitted.errors.length() != 0) {
        print("FAIL: valid WIR numeric cast was rejected: ", emitted.errors[0]);
        return 1;
    }
    let expected: String = "target triple = \"x86_64-pc-windows-msvc\"\n\ndefine internal i64 @casts(i32 %v1, i32 %v2, i64 %v3, double %v4) {\nb1:\n  %v6 = sext i32 %v1 to i64\n  %v7 = zext i32 %v2 to i64\n  %v8 = trunc i64 %v3 to i32\n  %v9 = sitofp i32 %v1 to double\n  %v10 = fptosi double %v4 to i64\n  %v12 = zext i32 %v1 to i64\n  %v13 = add i64 %v6, %v7\n  %v14 = add i64 %v13, %v10\n  %v15 = add i64 %v14, %v12\n  ret i64 %v15\n}\n";
    if (emitted.text != expected) {
        print("FAIL: WIR LLVM cast output is not stable");
        print(emitted.text);
        return 1;
    }
    print("PASS: WIR LLVM casts");
    return 0;
}
