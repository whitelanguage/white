// Test: X86_64_CASTS
// File: tests/machine/x86_64/test_casts.wl
// Focus: Preserve source bits through integer extension, truncation, and pointer casts.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import verify_wir from "../../../src/compiler/wir/verify.wl"
import * from "../../../src/compiler/machine/x86_64/lowering.wl"
import * from "../../../src/compiler/machine/x86_64/coff.wl"

struct CastCase(source_bits: Int, source_signed: Bool, target_bits: Int, target_signed: Bool, input: UInt64, expected: UInt64)

func integer_type(ref program: WirModule, bits: Int, signed: Bool) -> WirTypeID {
    if (bits == 1) { return program.bool_type; }
    if (signed) { return wir_signed_int_type(ref program, bits); }
    return wir_unsigned_int_type(ref program, bits);
}

func check(ref program: WirModule, function: WirFuncID, block: WirBlockID, actual: WirValueID, expected: WirValueID, code: Int) -> WirBlockID {
    let next: WirBlockID = wir_add_block(ref program, function, "next_" + code, []);
    let fail: WirBlockID = wir_add_block(ref program, function, "fail_" + code, []);
    let condition: WirValueID = wir_append(ref program, block, WirOpcode.Equal, program.bool_type, [actual, expected], [], no_wir_location());
    wir_append(ref program, block, WirOpcode.Branch, program.void_type, [condition], [wir_edge(next, []), wir_edge(fail, [])], no_wir_location());
    wir_return(ref program, fail, wir_const_int(ref program, wir_signed_int_type(ref program, 32), UInt128(UInt32(code))), no_wir_location());
    return next;
}

func main() -> Int {
    let cases: Vector(CastCase) = [
        CastCase(8, true, 64, true, 255UL, 18446744073709551615UL),
        CastCase(8, true, 16, true, 128UL, 65408UL),
        CastCase(8, true, 32, false, 156UL, 4294967196UL),
        CastCase(16, true, 64, true, 65436UL, 18446744073709551516UL),
        CastCase(32, true, 64, false, 2147483648UL, 18446744071562067968UL),
        CastCase(8, false, 64, false, 255UL, 255UL),
        CastCase(16, false, 32, true, 65535UL, 65535UL),
        CastCase(32, false, 64, false, 4294967295UL, 4294967295UL),
        CastCase(64, true, 32, true, 18446744073709551615UL, 4294967295UL),
        CastCase(64, false, 8, true, 4294967425UL, 129UL),
        CastCase(32, false, 16, false, 4294901761UL, 1UL),
        CastCase(8, false, 8, true, 255UL, 255UL),
        CastCase(16, true, 16, false, 65535UL, 65535UL),
        CastCase(32, false, 32, true, 2147483648UL, 2147483648UL),
        CastCase(64, false, 64, true, 9223372036854775808UL, 9223372036854775808UL),
        CastCase(8, false, 1, false, 2UL, 0UL),
        CastCase(8, false, 1, false, 3UL, 1UL),
        CastCase(1, false, 64, false, 1UL, 1UL)
    ];
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let u64: WirTypeID = wir_unsigned_int_type(ref program, 64);
    let pointer: WirTypeID = wir_pointer_type(ref program, wir_unsigned_int_type(ref program, 8));
    let main_id: WirFuncID = wir_add_function(ref program, "main", [], i32, false, WirLinkage.Exported, WirABI.White);
    let block: WirBlockID = wir_add_block(ref program, main_id, "entry", []);
    let i: Int = 0;
    while (i < cases.length()) {
        let item: CastCase = cases[i];
        let source_type: WirTypeID = integer_type(ref program, item.source_bits, item.source_signed);
        let target_type: WirTypeID = integer_type(ref program, item.target_bits, item.target_signed);
        let function: WirFuncID = wir_add_function(ref program, "cast_" + i, [WirParam(name="source", type_id=source_type)], target_type, false, WirLinkage.Internal, WirABI.White);
        let entry: WirBlockID = wir_add_block(ref program, function, "entry", []);
        let source: WirValueID = program.arena.functions[wir_id_index(UInt32(function))].parameters[0];
        let converted: WirValueID = wir_cast(ref program, entry, source, target_type, "converted", no_wir_location());
        wir_return(ref program, entry, converted, no_wir_location());
        let input: WirValueID = NO_WIR_VALUE;
        if (source_type == program.bool_type) { input = wir_const_bool(ref program, item.input != 0UL); }
        else { input = wir_const_int(ref program, source_type, UInt128(item.input)); }
        let expected: WirValueID = NO_WIR_VALUE;
        if (target_type == program.bool_type) { expected = wir_const_bool(ref program, item.expected != 0UL); }
        else { expected = wir_const_int(ref program, target_type, UInt128(item.expected)); }
        let signature: WirTypeID = wir_function_type(ref program, [source_type], target_type, false, WirABI.White);
        let actual: WirValueID = wir_call_typed(ref program, block, program.arena.functions[wir_id_index(UInt32(function))].address, signature, [input], "actual", no_wir_location());
        block = check(ref program, main_id, block, actual, expected, i + 1);
        i++;
    }
    // pointer casts do not dereference the address, including this deliberately unmapped one
    let address: WirValueID = wir_cast(ref program, block, wir_const_int(ref program, u64, UInt128(4294967299UL)), pointer, "address", no_wir_location());
    let restored: WirValueID = wir_cast(ref program, block, address, u64, "restored", no_wir_location());
    block = check(ref program, main_id, block, restored, wir_const_int(ref program, u64, UInt128(4294967299UL)), 19);
    let negative: WirValueID = wir_const_int(ref program, wir_signed_int_type(ref program, 8), UInt128(255U));
    let narrow_address: WirValueID = wir_cast(ref program, block, negative, pointer, "narrow_address", no_wir_location());
    let narrow_bits: WirValueID = wir_cast(ref program, block, narrow_address, u64, "narrow_bits", no_wir_location());
    block = check(ref program, main_id, block, narrow_bits, wir_const_int(ref program, u64, UInt128(255U)), 20);
    let original: WirValueID = wir_binary(ref program, block, WirOpcode.Add, u64, wir_const_int(ref program, u64, UInt128(4294967296UL)), wir_const_int(ref program, u64, UInt128(3U)), "original", no_wir_location());
    let low_bits: WirValueID = wir_cast(ref program, block, original, wir_unsigned_int_type(ref program, 8), "low_bits", no_wir_location());
    let preserved: WirValueID = wir_binary(ref program, block, WirOpcode.BitXor, u64, original, wir_cast(ref program, block, low_bits, u64, "extended", no_wir_location()), "preserved", no_wir_location());
    block = check(ref program, main_id, block, preserved, wir_const_int(ref program, u64, UInt128(4294967296UL)), 21);
    address = wir_cast(ref program, block, wir_const_int(ref program, u64, UInt128(4294967551UL)), pointer, "address", no_wir_location());
    let truncated_address: WirValueID = wir_cast(ref program, block, address, wir_signed_int_type(ref program, 8), "truncated_address", no_wir_location());
    block = check(ref program, main_id, block, truncated_address, wir_const_int(ref program, wir_signed_int_type(ref program, 8), UInt128(255U)), 22);
    address = wir_cast(ref program, block, wir_const_int(ref program, wir_signed_int_type(ref program, 16), UInt128(65535U)), pointer, "address", no_wir_location());
    restored = wir_cast(ref program, block, address, u64, "restored", no_wir_location());
    block = check(ref program, main_id, block, restored, wir_const_int(ref program, u64, UInt128(65535U)), 23);
    address = wir_cast(ref program, block, wir_const_int(ref program, i32, UInt128(4294967295U)), pointer, "address", no_wir_location());
    restored = wir_cast(ref program, block, address, u64, "restored", no_wir_location());
    block = check(ref program, main_id, block, restored, wir_const_int(ref program, u64, UInt128(4294967295UL)), 24);
    address = wir_cast(ref program, block, wir_const_int(ref program, u64, UInt128(4294967299UL)), pointer, "address", no_wir_location());
    let recast: WirValueID = wir_cast(ref program, block, address, wir_pointer_type(ref program, u64), "recast", no_wir_location());
    restored = wir_cast(ref program, block, recast, u64, "restored", no_wir_location());
    block = check(ref program, main_id, block, restored, wir_const_int(ref program, u64, UInt128(4294967299UL)), 25);
    wir_return(ref program, block, wir_const_int(ref program, i32, UInt128(0U)), no_wir_location());
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: invalid cast test: ", errors[0]);
        return 1;
    }
    let lowered: X86ModuleResult = x86_lower_module(ref program);
    if (lowered.errors.length() != 0) {
        print("FAIL: cast lowering: ", lowered.errors[0]);
        return 1;
    }
    let object: Vector(Byte) = coff_object_for_text_symbols(lowered.bytes, lowered.symbols, lowered.relocations)?;
    catch(err) {
        print("FAIL: cast COFF output");
        return 1;
    }
    print("PASS: x86_64 casts");
    print("OBJECT-BEGIN");
    i = 0;
    while (i < object.length()) {
        print(Int(object[i]));
        i++;
    }
    print("OBJECT-END");
    return 0;
}
