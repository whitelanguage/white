// Test: WIR_LLVM_ABS
// File: tests/integration/tooling/test_wir_llvm_abs.wl
// Focus: Lowering wrapping integer absolute value without LLVM overflow flags.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/backend/llvm.wl"

func main() -> Int {
    let program = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32 = wir_signed_int_type(ref program, 32);
    let function = wir_add_function(ref program, "abs", [wir_param("value", i32)], i32, false, WirLinkage.Exported, WirABI.White);
    let entry = wir_add_block(ref program, function, "entry", []);
    let value = program.arena.functions[wir_id_index(UInt32(function))].parameters[0];
    let result = wir_append(ref program, entry, WirOpcode.Abs, i32, [value], [], no_wir_location());
    wir_return(ref program, entry, result, no_wir_location());

    let emitted = emit_wir_llvm(program)?;
    catch(err) { print("FAIL: LLVM abs emission failed"); return 1; }
    let expected = "target triple = \"x86_64-pc-windows-msvc\"\n\ndefine i32 @abs(i32 %v1) {\nb1:\n  %v3.neg = sub i32 0, %v1\n  %v3.negative = icmp slt i32 %v1, 0\n  %v3 = select i1 %v3.negative, i32 %v3.neg, i32 %v1\n  ret i32 %v3\n}\n";
    let layout: String = "target datalayout = \"e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128\"\n";
    if (emitted.errors.length() != 0 || emitted.text != layout + expected) {
        print("FAIL: LLVM abs lowering");
        return 1;
    }
    print("PASS: WIR LLVM abs");
    return 0;
}
