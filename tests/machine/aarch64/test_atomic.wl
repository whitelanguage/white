// Test: AARCH64_ATOMIC
// File: tests/machine/aarch64/test_atomic.wl
// Focus: Lower atomic loads, stores, and LL/SC read-modify-write loops with their WIR memory orders.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import verify_wir from "../../../src/compiler/wir/verify.wl"
import * from "../../../src/compiler/machine/aarch64/lowering.wl"


func word_at(bytes: Vector(Byte), offset: Int) -> UInt32 {
    return UInt32(bytes[offset]) |
           (UInt32(bytes[offset + 1]) << 8U) |
           (UInt32(bytes[offset + 2]) << 16U) |
           (UInt32(bytes[offset + 3]) << 24U);
}

func has_word(bytes: Vector(Byte), expected: UInt32, mask: UInt32) -> Bool {
    let i: Int = 0;
    while (i + 3 < bytes.length()) {
        if ((word_at(bytes, i) & mask) == expected) {
            return true;
        }
        i += 4;
    }

    return false;
}

func add_load(ref program: WirModule, name: String, int_type: WirTypeID, order: WirMemoryOrder) -> Void {
    let pointer: WirTypeID = wir_pointer_type(ref program, int_type);
    let function: WirFuncID = wir_add_function(ref program, name, [WirParam(name="address", type_id=pointer)], int_type, false, WirLinkage.Exported, WirABI.C);
    let block: WirBlockID = wir_add_block(ref program, function, "entry", []);
    let address: WirValueID = program.arena.functions[wir_id_index(UInt32(function))].parameters[0];
    let value: WirValueID = wir_atomic_load(ref program, block, address, order, "value", no_wir_location());
    wir_return(ref program, block, value, no_wir_location());
}

func add_store(ref program: WirModule, name: String, int_type: WirTypeID, order: WirMemoryOrder) -> Void {
    let pointer: WirTypeID = wir_pointer_type(ref program, int_type);
    let function: WirFuncID = wir_add_function(ref program, name, [WirParam(name="address", type_id=pointer), WirParam(name="value", type_id=int_type)], program.void_type, false, WirLinkage.Exported, WirABI.C);
    let block: WirBlockID = wir_add_block(ref program, function, "entry", []);
    let params: Vector(WirValueID) = program.arena.functions[wir_id_index(UInt32(function))].parameters;
    wir_atomic_store(ref program, block, params[1], params[0], order, no_wir_location());
    wir_return(ref program, block, NO_WIR_VALUE, no_wir_location());
}

func add_rmw(ref program: WirModule, name: String, operation: WirAtomicOp, order: WirMemoryOrder) -> Void {
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let pointer: WirTypeID = wir_pointer_type(ref program, i32);
    let function: WirFuncID = wir_add_function(ref program, name, [WirParam(name="address", type_id=pointer), WirParam(name="value", type_id=i32)], i32, false, WirLinkage.Exported, WirABI.C);
    let block: WirBlockID = wir_add_block(ref program, function, "entry", []);
    let params: Vector(WirValueID) = program.arena.functions[wir_id_index(UInt32(function))].parameters;
    let old: WirValueID = wir_atomic_rmw(ref program, block, operation, params[0], params[1], order, "old", no_wir_location());
    wir_return(ref program, block, old, no_wir_location());
}

func main() -> Int {
    let program: WirModule = new_wir_module("aarch64-unknown-linux-gnu", 64);
    let i8: WirTypeID = wir_signed_int_type(ref program, 8);
    let i16: WirTypeID = wir_signed_int_type(ref program, 16);
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let i64: WirTypeID = wir_signed_int_type(ref program, 64);

    add_load(ref program, "load8", i8, WirMemoryOrder.Relaxed);
    add_load(ref program, "load16", i16, WirMemoryOrder.Acquire);
    add_load(ref program, "load32", i32, WirMemoryOrder.SequentiallyConsistent);
    add_load(ref program, "load64", i64, WirMemoryOrder.Relaxed);
    add_store(ref program, "store8", i8, WirMemoryOrder.Relaxed);
    add_store(ref program, "store16", i16, WirMemoryOrder.Release);
    add_store(ref program, "store32", i32, WirMemoryOrder.SequentiallyConsistent);
    add_store(ref program, "store64", i64, WirMemoryOrder.Relaxed);

    add_rmw(ref program, "exchange", WirAtomicOp.Exchange, WirMemoryOrder.Relaxed);
    add_rmw(ref program, "add", WirAtomicOp.Add, WirMemoryOrder.Acquire);
    add_rmw(ref program, "subtract", WirAtomicOp.Subtract, WirMemoryOrder.Release);
    add_rmw(ref program, "bit_and", WirAtomicOp.BitAnd, WirMemoryOrder.AcquireRelease);
    add_rmw(ref program, "bit_or", WirAtomicOp.BitOr, WirMemoryOrder.SequentiallyConsistent);
    add_rmw(ref program, "bit_xor", WirAtomicOp.BitXor, WirMemoryOrder.Relaxed);

    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: invalid AArch64 atomic test: ", errors[0]);
        return 1;
    }

    let lowered: A64ModuleResult = a64_lower_module(ref program);
    if (lowered.errors.length() != 0) {
        print("FAIL: AArch64 atomic lowering: ", lowered.errors[0]);
        return 1;
    }

    let bytes: Vector(Byte) = lowered.sections[0].bytes;
    if (!has_word(bytes, 0x39400000U, 0xFFFFFC00U) || !has_word(bytes, 0x48DFFC00U, 0xFFFFFC00U) ||
        !has_word(bytes, 0x88DFFC00U, 0xFFFFFC00U) || !has_word(bytes, 0xF9400000U, 0xFFFFFC00U) ||
        !has_word(bytes, 0x39000000U, 0xFFFFFC00U) || !has_word(bytes, 0x489FFC00U, 0xFFFFFC00U) ||
        !has_word(bytes, 0x889FFC00U, 0xFFFFFC00U) || !has_word(bytes, 0xF9000000U, 0xFFFFFC00U) ||
        !has_word(bytes, 0x885F7C00U, 0xFFFFFC00U) || !has_word(bytes, 0x885FFC00U, 0xFFFFFC00U) ||
        !has_word(bytes, 0x88007C00U, 0xFFE0FC00U) || !has_word(bytes, 0x8800FC00U, 0xFFE0FC00U)) {
        print("FAIL: AArch64 atomic instruction selection");
        return 1;
    }

    print("PASS: AArch64 atomic memory operations");
    return 0;
}
