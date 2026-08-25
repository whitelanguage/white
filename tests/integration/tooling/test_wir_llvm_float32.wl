// Test: WIR_LLVM_FLOAT32
// File: tests/integration/tooling/test_wir_llvm_float32.wl
// Focus: Preserving every Float32 class while writing LLVM constants.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/backend/llvm.wl"

func main() -> Int {
    if (llvm_float32_bits(1065353216UL) != 4607182418800017408UL) { print("FAIL: normal Float32 conversion"); return 1; }
    if (llvm_float32_bits(2147483648UL) != 9223372036854775808UL) { print("FAIL: negative zero conversion"); return 1; }
    if (llvm_float32_bits(2139095040UL) != 9218868437227405312UL) { print("FAIL: infinity conversion"); return 1; }
    if (llvm_float32_bits(1UL) != 3936146074321813504UL) { print("FAIL: subnormal Float32 conversion"); return 1; }
    if (llvm_float32_bits(2143289345UL) != 9221120237577961472UL) { print("FAIL: NaN payload conversion"); return 1; }

    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let f32_type: WirTypeID = wir_float_type(ref program, 32);
    let one_id: WirFuncID = wir_add_function(ref program, "one", [], f32_type, false, WirLinkage.Internal, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, one_id, "entry", []);
    let one: WirValueID = wir_const_float_bits(ref program, f32_type, 1065353216UL);
    wir_return(ref program, entry, one, no_wir_location());

    let emitted: WirLLVMResult = emit_wir_llvm(program)?;
    catch(err) { print("FAIL: Float32 LLVM emission failed"); return 1; }
    if (emitted.errors.length() != 0) { print("FAIL: valid Float32 WIR was rejected"); return 1; }

    let expected: String = "target triple = \"x86_64-pc-windows-msvc\"\n\ndefine internal float @one() {\nb1:\n  ret float 0x3FF0000000000000\n}\n";
    if (emitted.text != expected) { print("FAIL: Float32 LLVM output is not stable"); return 1; }

    print("PASS: WIR LLVM Float32 constants");
    return 0;
}
