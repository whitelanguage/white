// Test: WIR_ATOMICS
// File: tests/integration/tooling/test_wir_atomics.wl
// Focus: Verifying and lowering low-level atomic memory operations.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/verify.wl"
import * from "../../../src/compiler/wir/backend/llvm.wl"

func has_error(errors: Vector(String), expected: String) -> Bool {
    let i: Int = 0;
    while (i < errors.length()) {
        if (errors[i] == expected) { return true; }
        i++;
    }
    return false;
}

func rejects_invalid_load_order() -> Bool {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let function_id: WirFuncID = wir_add_function(ref program, "bad_atomic", [], i32_type, false, WirLinkage.Internal, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let slot: WirValueID = wir_stack_alloc(ref program, entry, i32_type, "slot", no_wir_location());
    let value: WirValueID = wir_atomic_load(ref program, entry, slot, WirMemoryOrder.Release, "value", no_wir_location());
    wir_return(ref program, entry, value, no_wir_location());
    return has_error(verify_wir(program), "atomic load has an invalid memory order");
}

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let function_id: WirFuncID = wir_add_function(ref program, "atomic_counter", [], i32_type, false, WirLinkage.Internal, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let slot: WirValueID = wir_stack_alloc(ref program, entry, i32_type, "slot", no_wir_location());
    let zero: WirValueID = wir_const_int(ref program, i32_type, UInt128(0U));
    let one: WirValueID = wir_const_int(ref program, i32_type, UInt128(1U));
    wir_atomic_store(ref program, entry, zero, slot, WirMemoryOrder.SequentiallyConsistent, no_wir_location());
    wir_atomic_load(ref program, entry, slot, WirMemoryOrder.Acquire, "loaded", no_wir_location());
    wir_atomic_rmw(ref program, entry, WirAtomicOp.Add, slot, one, WirMemoryOrder.Relaxed, "before_add", no_wir_location());
    let result: WirValueID = wir_atomic_rmw(ref program, entry, WirAtomicOp.Subtract, slot, one, WirMemoryOrder.AcquireRelease, "before_sub", no_wir_location());
    wir_return(ref program, entry, result, no_wir_location());

    let emitted: WirLLVMResult = emit_wir_llvm(program)?;
    catch(err) { print("FAIL: atomic LLVM emission failed"); return 1; }
    if (emitted.errors.length() != 0) { print("FAIL: valid atomic WIR was rejected: ", emitted.errors[0]); return 1; }
    let expected: String = "target triple = \"x86_64-pc-windows-msvc\"\n\ndefine internal i32 @atomic_counter() {\nb1:\n  %v2 = alloca i32\n  store atomic i32 0, ptr %v2 seq_cst, align 4\n  %v5 = load atomic i32, ptr %v2 acquire, align 4\n  %v6 = atomicrmw add ptr %v2, i32 1 monotonic\n  %v7 = atomicrmw sub ptr %v2, i32 1 acq_rel\n  ret i32 %v7\n}\n";
    if (emitted.text != expected) { print("FAIL: atomic LLVM output is not stable"); print(emitted.text); return 1; }
    if (!rejects_invalid_load_order()) { print("FAIL: invalid atomic load order was accepted"); return 1; }
    print("PASS: WIR atomic operations");
    return 0;
}
