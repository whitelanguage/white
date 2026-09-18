// Test: X86_64_ADDRESSES
// File: tests/machine/x86_64/test_addresses.wl
// Focus: Execute padded field addresses, scaled indices, negative indices, and indirect loads/stores.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import verify_wir from "../../../src/compiler/wir/verify.wl"
import * from "../../../src/compiler/machine/x86_64/lowering.wl"
import * from "../../../src/compiler/machine/x86_64/coff.wl"

func check(ref program: WirModule, function: WirFuncID, block: WirBlockID, actual: WirValueID, expected: WirValueID, code: Int) -> WirBlockID {
    let next: WirBlockID = wir_add_block(ref program, function, "next_" + code, []);
    let fail: WirBlockID = wir_add_block(ref program, function, "fail_" + code, []);
    let condition: WirValueID = wir_append(ref program, block, WirOpcode.Equal, program.bool_type, [actual, expected], [], no_wir_location());
    wir_append(ref program, block, WirOpcode.Branch, program.void_type, [condition], [wir_edge(next, []), wir_edge(fail, [])], no_wir_location());
    wir_return(ref program, fail, wir_const_int(ref program, wir_signed_int_type(ref program, 32), UInt128(UInt32(code))), no_wir_location());
    return next;
}

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i8: WirTypeID = wir_signed_int_type(ref program, 8);
    let u8: WirTypeID = wir_unsigned_int_type(ref program, 8);
    let u16: WirTypeID = wir_unsigned_int_type(ref program, 16);
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let i64: WirTypeID = wir_signed_int_type(ref program, 64);
    let u64: WirTypeID = wir_unsigned_int_type(ref program, 64);
    let triple: WirTypeID = wir_struct_type(ref program, [i32, i32, i32]);
    let record: WirTypeID = wir_struct_type(ref program, [i8, i64, wir_array_type(ref program, i32, UIntSize(4)), wir_array_type(ref program, triple, UIntSize(3))]);
    let pointer: WirTypeID = wir_pointer_type(ref program, i64);
    let helper: WirFuncID = wir_add_function(ref program, "write_and_read", [WirParam(name="address", type_id=pointer), WirParam(name="value", type_id=i64), WirParam(name="amount", type_id=i32)], i64, false, WirLinkage.Internal, WirABI.White);
    let helper_entry: WirBlockID = wir_add_block(ref program, helper, "entry", []);
    let parameters: Vector(WirValueID) = program.arena.functions[wir_id_index(UInt32(helper))].parameters;
    // the shift forces parameter homes; a pointer's home is not the pointed-to object
    let shifted: WirValueID = wir_binary(ref program, helper_entry, WirOpcode.ShiftLeft, i32, parameters[2], wir_const_int(ref program, i32, UInt128(1U)), "shifted", no_wir_location());
    wir_store(ref program, helper_entry, parameters[1], parameters[0], no_wir_location());
    let loaded: WirValueID = wir_load(ref program, helper_entry, parameters[0], "loaded", no_wir_location());
    let sum: WirValueID = wir_binary(ref program, helper_entry, WirOpcode.Add, i64, loaded, wir_cast(ref program, helper_entry, shifted, i64, "extended", no_wir_location()), "sum", no_wir_location());
    wir_return(ref program, helper_entry, sum, no_wir_location());

    let main_id: WirFuncID = wir_add_function(ref program, "main", [], i32, false, WirLinkage.Exported, WirABI.White);
    let block: WirBlockID = wir_add_block(ref program, main_id, "entry", []);
    let storage: WirValueID = wir_stack_alloc(ref program, block, record, "record", no_wir_location());
    let words: WirValueID = wir_stack_alloc(ref program, block, wir_array_type(ref program, u16, UIntSize(4)), "words", no_wir_location());
    let byte_field: WirValueID = wir_field_address(ref program, block, storage, 0, "byte", no_wir_location());
    wir_store(ref program, block, wir_const_int(ref program, i8, UInt128(253U)), byte_field, no_wir_location());
    block = check(ref program, main_id, block, wir_load(ref program, block, byte_field, "byte_value", no_wir_location()), wir_const_int(ref program, i8, UInt128(253U)), 1);
    let wide_field: WirValueID = wir_field_address(ref program, block, storage, 1, "wide", no_wir_location());
    let signature: WirTypeID = wir_function_type(ref program, [pointer, i64, i32], i64, false, WirABI.White);
    let result: WirValueID = wir_call_typed(ref program, block, program.arena.functions[wir_id_index(UInt32(helper))].address, signature, [wide_field, wir_const_int(ref program, i64, UInt128(4294967299UL)), wir_const_int(ref program, i32, UInt128(2U))], "result", no_wir_location());
    block = check(ref program, main_id, block, result, wir_const_int(ref program, i64, UInt128(4294967303UL)), 2);
    wide_field = wir_field_address(ref program, block, storage, 1, "wide", no_wir_location());
    let zero_index: WirValueID = wir_index_address(ref program, block, wide_field, wir_const_int(ref program, i32, UInt128(0U)), "wide_zero", no_wir_location());
    block = check(ref program, main_id, block, wir_load(ref program, block, zero_index, "wide_value", no_wir_location()), wir_const_int(ref program, i64, UInt128(4294967299UL)), 3);
    let array_field: WirValueID = wir_field_address(ref program, block, storage, 2, "array", no_wir_location());
    let first: WirValueID = wir_index_address(ref program, block, array_field, wir_const_int(ref program, i32, UInt128(1U)), "first", no_wir_location());
    let second: WirValueID = wir_index_address(ref program, block, array_field, wir_const_int(ref program, i32, UInt128(2U)), "second", no_wir_location());
    wir_store(ref program, block, wir_const_int(ref program, i32, UInt128(33U)), first, no_wir_location());
    wir_store(ref program, block, wir_const_int(ref program, i32, UInt128(44U)), second, no_wir_location());
    let previous: WirValueID = wir_index_address(ref program, block, second, wir_const_int(ref program, i32, UInt128(4294967295U)), "previous", no_wir_location());
    block = check(ref program, main_id, block, wir_load(ref program, block, previous, "previous_value", no_wir_location()), wir_const_int(ref program, i32, UInt128(33U)), 4);
    let triples: WirValueID = wir_field_address(ref program, block, storage, 3, "triples", no_wir_location());
    let element: WirValueID = wir_index_address(ref program, block, triples, wir_const_int(ref program, i32, UInt128(2U)), "element", no_wir_location());
    let member: WirValueID = wir_field_address(ref program, block, element, 2, "member", no_wir_location());
    wir_store(ref program, block, wir_const_int(ref program, i32, UInt128(55U)), member, no_wir_location());
    block = check(ref program, main_id, block, wir_load(ref program, block, member, "member_value", no_wir_location()), wir_const_int(ref program, i32, UInt128(55U)), 5);
    triples = wir_field_address(ref program, block, storage, 3, "triples", no_wir_location());
    element = wir_index_address(ref program, block, triples, wir_const_int(ref program, i32, UInt128(2U)), "element", no_wir_location());
    let distance: WirValueID = wir_binary(ref program, block, WirOpcode.Subtract, u64, wir_cast(ref program, block, element, u64, "end_bits", no_wir_location()), wir_cast(ref program, block, triples, u64, "start_bits", no_wir_location()), "distance", no_wir_location());
    block = check(ref program, main_id, block, distance, wir_const_int(ref program, u64, UInt128(24U)), 6);
    wide_field = wir_field_address(ref program, block, storage, 1, "wide", no_wir_location());
    let bytes: WirValueID = wir_cast(ref program, block, wide_field, wir_pointer_type(ref program, u8), "bytes", no_wir_location());
    let high_byte: WirValueID = wir_index_address(ref program, block, bytes, wir_const_int(ref program, i32, UInt128(4U)), "high_byte", no_wir_location());
    block = check(ref program, main_id, block, wir_load(ref program, block, high_byte, "high_byte_value", no_wir_location()), wir_const_int(ref program, u8, UInt128(1U)), 7);
    let word: WirValueID = wir_index_address(ref program, block, words, wir_const_int(ref program, i32, UInt128(3U)), "word", no_wir_location());
    wir_store(ref program, block, wir_const_int(ref program, u16, UInt128(65535U)), word, no_wir_location());
    block = check(ref program, main_id, block, wir_load(ref program, block, word, "word_value", no_wir_location()), wir_const_int(ref program, u16, UInt128(65535U)), 8);
    array_field = wir_field_address(ref program, block, storage, 2, "array", no_wir_location());
    // inspect the arithmetic only; this address is not used for a memory access
    let far: WirValueID = wir_index_address(ref program, block, array_field, wir_const_int(ref program, wir_unsigned_int_type(ref program, 32), UInt128(4294967295U)), "far", no_wir_location());
    distance = wir_binary(ref program, block, WirOpcode.Subtract, u64, wir_cast(ref program, block, far, u64, "far_bits", no_wir_location()), wir_cast(ref program, block, array_field, u64, "array_bits", no_wir_location()), "distance", no_wir_location());
    block = check(ref program, main_id, block, distance, wir_const_int(ref program, u64, UInt128(17179869180UL)), 9);
    wir_return(ref program, block, wir_const_int(ref program, i32, UInt128(0U)), no_wir_location());

    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: invalid address test: ", errors[0]);
        return 1;
    }
    let lowered: X86ModuleResult = x86_lower_module(program);
    if (lowered.errors.length() != 0) {
        print("FAIL: address lowering: ", lowered.errors[0]);
        return 1;
    }
    let object: Vector(Byte) = coff_object_for_text_symbols(lowered.bytes, lowered.symbols, lowered.relocations)?;
    catch(err) {
        print("FAIL: address COFF output");
        return 1;
    }
    print("PASS: x86_64 addresses");
    print("OBJECT-BEGIN");
    let i: Int = 0;
    while (i < object.length()) {
        print(Int(object[i]));
        i++;
    }
    print("OBJECT-END");
    return 0;
}
