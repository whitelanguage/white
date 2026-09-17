// Test: X86_64_SCALAR_WIDTHS
// File: tests/machine/x86_64/test_scalar_widths.wl
// Focus: Preserve scalar widths through Win64 calls, stack slots, arithmetic, and returns.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/machine/x86_64/lowering.wl"
import * from "../../../src/compiler/machine/x86_64/coff.wl"

func add_check(ref program: WirModule, block: WirBlockID, value: WirValueID, expected: WirValueID, pass: WirBlockID, fail: WirBlockID) -> Void {
    let condition: WirValueID = wir_append(ref program, block, WirOpcode.Equal, program.bool_type, [value, expected], [], no_wir_location());
    wir_append(ref program, block, WirOpcode.Branch, program.void_type, [condition], [wir_edge(pass, []), wir_edge(fail, [])], no_wir_location());
}

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i8: WirTypeID = wir_signed_int_type(ref program, 8);
    let i16: WirTypeID = wir_signed_int_type(ref program, 16);
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let i64: WirTypeID = wir_signed_int_type(ref program, 64);
    let pointer: WirTypeID = wir_pointer_type(ref program, i8);

    let wide_id: WirFuncID = wir_add_function(ref program, "wide_six", [
        WirParam(name="a", type_id=i64), WirParam(name="b", type_id=i64),
        WirParam(name="c", type_id=i64), WirParam(name="d", type_id=i64),
        WirParam(name="e", type_id=i64), WirParam(name="f", type_id=i64)
    ], i64, false, WirLinkage.Internal, WirABI.White);
    let wide_entry: WirBlockID = wir_add_block(ref program, wide_id, "entry", []);
    let wide_value: WirValueID = program.arena.functions[wir_id_index(UInt32(wide_id))].parameters[0];
    let i: Int = 1;
    while (i < 6) {
        wide_value = wir_binary(ref program, wide_entry, WirOpcode.Add, i64, wide_value, program.arena.functions[wir_id_index(UInt32(wide_id))].parameters[i], "sum", no_wir_location());
        i += 1;
    }
    wir_return(ref program, wide_entry, wide_value, no_wir_location());

    let byte_id: WirFuncID = wir_add_function(ref program, "keep_byte", [], i8, false, WirLinkage.Internal, WirABI.White);
    let byte_entry: WirBlockID = wir_add_block(ref program, byte_id, "entry", []);
    let first_byte: WirValueID = wir_stack_alloc(ref program, byte_entry, i8, "first", no_wir_location());
    let second_byte: WirValueID = wir_stack_alloc(ref program, byte_entry, i8, "second", no_wir_location());
    wir_store(ref program, byte_entry, wir_const_int(ref program, i8, UInt128(17U)), first_byte, no_wir_location());
    wir_store(ref program, byte_entry, wir_const_int(ref program, i8, UInt128(34U)), second_byte, no_wir_location());
    wir_return(ref program, byte_entry, wir_load(ref program, byte_entry, first_byte, "loaded", no_wir_location()), no_wir_location());

    let word_id: WirFuncID = wir_add_function(ref program, "keep_word", [], i16, false, WirLinkage.Internal, WirABI.White);
    let word_entry: WirBlockID = wir_add_block(ref program, word_id, "entry", []);
    let first_word: WirValueID = wir_stack_alloc(ref program, word_entry, i16, "first", no_wir_location());
    let second_word: WirValueID = wir_stack_alloc(ref program, word_entry, i16, "second", no_wir_location());
    wir_store(ref program, word_entry, wir_const_int(ref program, i16, UInt128(1234U)), first_word, no_wir_location());
    wir_store(ref program, word_entry, wir_const_int(ref program, i16, UInt128(5678U)), second_word, no_wir_location());
    wir_return(ref program, word_entry, wir_load(ref program, word_entry, first_word, "loaded", no_wir_location()), no_wir_location());

    let stack_id: WirFuncID = wir_add_function(ref program, "keep_long", [], i64, false, WirLinkage.Internal, WirABI.White);
    let stack_entry: WirBlockID = wir_add_block(ref program, stack_id, "entry", []);
    let long_slot: WirValueID = wir_stack_alloc(ref program, stack_entry, i64, "value", no_wir_location());
    let long_value: WirValueID = wir_const_int(ref program, i64, UInt128(4294967299UL));
    wir_store(ref program, stack_entry, long_value, long_slot, no_wir_location());
    wir_return(ref program, stack_entry, wir_load(ref program, stack_entry, long_slot, "loaded", no_wir_location()), no_wir_location());

    let pointer_id: WirFuncID = wir_add_function(ref program, "pointer_echo", [WirParam(name="value", type_id=pointer)], pointer, false, WirLinkage.Internal, WirABI.White);
    let pointer_entry: WirBlockID = wir_add_block(ref program, pointer_id, "entry", []);
    wir_return(ref program, pointer_entry, program.arena.functions[wir_id_index(UInt32(pointer_id))].parameters[0], no_wir_location());

    let main_id: WirFuncID = wir_add_function(ref program, "main", [], i32, false, WirLinkage.Exported, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, main_id, "entry", []);
    let byte_check: WirBlockID = wir_add_block(ref program, main_id, "byte", []);
    let word_check: WirBlockID = wir_add_block(ref program, main_id, "word", []);
    let stack_check: WirBlockID = wir_add_block(ref program, main_id, "stack", []);
    let pointer_check: WirBlockID = wir_add_block(ref program, main_id, "pointer", []);
    let success: WirBlockID = wir_add_block(ref program, main_id, "success", []);
    let failure: WirBlockID = wir_add_block(ref program, main_id, "failure", []);

    let wide_type: WirTypeID = wir_function_type(ref program, [i64, i64, i64, i64, i64, i64], i64, false, WirABI.White);
    let wide_result: WirValueID = wir_call_typed(ref program, entry, program.arena.functions[wir_id_index(UInt32(wide_id))].address, wide_type, [
        wir_const_int(ref program, i64, UInt128(4294967296UL)), wir_const_int(ref program, i64, UInt128(2U)),
        wir_const_int(ref program, i64, UInt128(3U)), wir_const_int(ref program, i64, UInt128(4U)),
        wir_const_int(ref program, i64, UInt128(5U)), wir_const_int(ref program, i64, UInt128(6U))
    ], "wide", no_wir_location());
    add_check(ref program, entry, wide_result, wir_const_int(ref program, i64, UInt128(4294967316UL)), byte_check, failure);

    let byte_type: WirTypeID = wir_function_type(ref program, [], i8, false, WirABI.White);
    let byte_result: WirValueID = wir_call_typed(ref program, byte_check, program.arena.functions[wir_id_index(UInt32(byte_id))].address, byte_type, [], "byte", no_wir_location());
    add_check(ref program, byte_check, byte_result, wir_const_int(ref program, i8, UInt128(17U)), word_check, failure);

    let word_type: WirTypeID = wir_function_type(ref program, [], i16, false, WirABI.White);
    let word_result: WirValueID = wir_call_typed(ref program, word_check, program.arena.functions[wir_id_index(UInt32(word_id))].address, word_type, [], "word", no_wir_location());
    add_check(ref program, word_check, word_result, wir_const_int(ref program, i16, UInt128(1234U)), stack_check, failure);

    let stack_type: WirTypeID = wir_function_type(ref program, [], i64, false, WirABI.White);
    let stack_result: WirValueID = wir_call_typed(ref program, stack_check, program.arena.functions[wir_id_index(UInt32(stack_id))].address, stack_type, [], "long", no_wir_location());
    add_check(ref program, stack_check, stack_result, long_value, pointer_check, failure);

    let pointer_type: WirTypeID = wir_function_type(ref program, [pointer], pointer, false, WirABI.White);
    let null_value: WirValueID = wir_null(ref program, pointer);
    let pointer_result: WirValueID = wir_call_typed(ref program, pointer_check, program.arena.functions[wir_id_index(UInt32(pointer_id))].address, pointer_type, [null_value], "pointer", no_wir_location());
    add_check(ref program, pointer_check, pointer_result, null_value, success, failure);

    wir_return(ref program, success, wir_const_int(ref program, i32, UInt128(0U)), no_wir_location());
    wir_return(ref program, failure, wir_const_int(ref program, i32, UInt128(1U)), no_wir_location());

    let lowered: X86ModuleResult = x86_lower_module(program);
    if (lowered.errors.length() != 0) {
        print("FAIL: x86_64 scalar lowering failed: ", lowered.errors[0]);
        return 1;
    }
    if (lowered.symbols.length() != 6) {
        print("FAIL: x86_64 scalar module has the wrong symbol count");
        return 1;
    }

    let object: Vector(Byte) = coff_object_for_text_symbols(lowered.bytes, lowered.symbols, lowered.relocations)?;
    catch(err) {
        print("FAIL: could not write scalar test object");
        return 1;
    }
    print("PASS: x86_64 scalar widths");
    print("OBJECT-BEGIN");
    let byte_index: Int = 0;
    while (byte_index < object.length()) {
        print(Int(object[byte_index]));
        byte_index += 1;
    }
    print("OBJECT-END");
    return 0;
}
