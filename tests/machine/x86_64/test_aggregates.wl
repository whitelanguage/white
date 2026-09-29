// Test: X86_64_AGGREGATES
// File: tests/machine/x86_64/test_aggregates.wl
// Focus: Value snapshots, padded layouts, loop-carried swaps, and edge register pressure.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import verify_wir from "../../../src/compiler/wir/verify.wl"
import * from "../../../src/compiler/machine/x86_64/lowering.wl"
import X86Object from "../../../src/compiler/machine/x86_64/model.wl"
import coff_object from "../../../src/compiler/machine/x86_64/coff.wl"

func expect(ref program: WirModule, function: WirFuncID, block: WirBlockID, actual: WirValueID, expected: WirValueID, code: Int) -> WirBlockID {
    let next: WirBlockID = wir_add_block(ref program, function, "next_" + code, []);
    let fail: WirBlockID = wir_add_block(ref program, function, "fail_" + code, []);
    let equal: WirValueID = wir_append(ref program, block, WirOpcode.Equal, program.bool_type, [actual, expected], [], no_wir_location());
    wir_append(ref program, block, WirOpcode.Branch, program.void_type, [equal], [wir_edge(next, []), wir_edge(fail, [])], no_wir_location());
    wir_return(ref program, fail, wir_const_int(ref program, wir_signed_int_type(ref program, 32), UInt128(UInt32(code))), no_wir_location());
    return next;
}

func array_case(ref program: WirModule, length: Int) -> WirFuncID {
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let byte: WirTypeID = wir_unsigned_int_type(ref program, 8);
    let array: WirTypeID = wir_array_type(ref program, byte, UIntSize(length));
    let function: WirFuncID = wir_add_function(ref program, "array_" + length, [WirParam(name="marker", type_id=i32)], i32, false, WirLinkage.Internal, WirABI.White);
    let block: WirBlockID = wir_add_block(ref program, function, "entry", []);
    let elements: Vector(WirValueID) = [];
    let i: Int = 0;
    while (i < length) {
        elements.append(wir_const_int(ref program, byte, UInt128(UInt32(i % 251))));
        i++;
    }
    let value: WirValueID = wir_array_value(ref program, block, array, elements, "value", no_wir_location());
    let first: WirValueID = wir_stack_alloc(ref program, block, array, "first", no_wir_location());
    let second: WirValueID = wir_stack_alloc(ref program, block, array, "second", no_wir_location());
    wir_store(ref program, block, value, first, no_wir_location());
    let snapshot: WirValueID = wir_load(ref program, block, first, "snapshot", no_wir_location());
    wir_store(ref program, block, snapshot, second, no_wir_location());
    let last: WirValueID = wir_const_int(ref program, i32, UInt128(UInt32(length - 1)));
    let address: WirValueID = wir_index_address(ref program, block, first, last, "last", no_wir_location());
    wir_store(ref program, block, wir_const_int(ref program, byte, UInt128(255U)), address, no_wir_location());
    let expected: WirValueID = elements[length - 1];
    block = expect(ref program, function, block, wir_index(ref program, block, snapshot, last, "", no_wir_location()), expected, 10);
    block = expect(ref program, function, block, wir_index(ref program, block, value, last, "", no_wir_location()), expected, 11);
    let copied: WirValueID = wir_load(ref program, block, second, "copied", no_wir_location());
    block = expect(ref program, function, block, wir_index(ref program, block, copied, last, "", no_wir_location()), expected, 12);
    // RCX is also the incoming marker register; a bulk-copy counter must not lose it
    let marker: WirValueID = program.arena.functions[wir_id_index(UInt32(function))].parameters[0];
    block = expect(ref program, function, block, marker, wir_const_int(ref program, i32, UInt128(42U)), 13);
    wir_return(ref program, block, wir_const_int(ref program, i32, UInt128(0U)), no_wir_location());
    return function;
}

func record_case(ref program: WirModule) -> WirFuncID {
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let byte: WirTypeID = wir_unsigned_int_type(ref program, 8);
    let word: WirTypeID = wir_unsigned_int_type(ref program, 16);
    let f64: WirTypeID = wir_float_type(ref program, 64);
    let record: WirTypeID = wir_struct_type(ref program, [byte, f64, word]);
    let outer: WirTypeID = wir_struct_type(ref program, [byte, record]);
    let function: WirFuncID = wir_add_function(ref program, "record", [], i32, false, WirLinkage.Internal, WirABI.White);
    let block: WirBlockID = wir_add_block(ref program, function, "entry", []);
    let seven: WirValueID = wir_const_int(ref program, byte, UInt128(7U));
    let fraction: WirValueID = wir_const_float(ref program, f64, 2.5);
    let number: WirValueID = wir_const_int(ref program, word, UInt128(3000U));
    let value: WirValueID = wir_struct_value(ref program, block, record, [seven, fraction, number], "value", no_wir_location());
    let nested: WirValueID = wir_struct_value(ref program, block, outer, [seven, value], "nested", no_wir_location());
    let slot: WirValueID = wir_stack_alloc(ref program, block, outer, "slot", no_wir_location());
    wir_store(ref program, block, nested, slot, no_wir_location());
    let snapshot: WirValueID = wir_load(ref program, block, slot, "snapshot", no_wir_location());
    let inner_address: WirValueID = wir_field_address(ref program, block, slot, 1, "inner", no_wir_location());
    let field_address: WirValueID = wir_field_address(ref program, block, inner_address, 0, "field", no_wir_location());
    wir_store(ref program, block, wir_const_int(ref program, byte, UInt128(99U)), field_address, no_wir_location());
    let inner: WirValueID = wir_field(ref program, block, snapshot, 1, "inner_value", no_wir_location());
    block = expect(ref program, function, block, wir_field(ref program, block, inner, 0, "", no_wir_location()), seven, 20);
    block = expect(ref program, function, block, wir_field(ref program, block, inner, 1, "", no_wir_location()), fraction, 21);
    block = expect(ref program, function, block, wir_field(ref program, block, inner, 2, "", no_wir_location()), number, 22);
    let bytes: WirValueID = wir_append(ref program, block, WirOpcode.Bitcast, wir_pointer_type(ref program, byte), [inner_address], [], no_wir_location());
    let padding: Vector(Int) = [1, 7, 18, 23];
    let i: Int = 0;
    while (i < padding.length()) {
        let address: WirValueID = wir_index_address(ref program, block, bytes, wir_const_int(ref program, i32, UInt128(UInt32(padding[i]))), "padding", no_wir_location());
        block = expect(ref program, function, block, wir_load(ref program, block, address, "", no_wir_location()), wir_const_int(ref program, byte, UInt128(0U)), 23 + i);
        i++;
    }
    wir_store(ref program, block, wir_const_zero(ref program, outer), slot, no_wir_location());
    let cleared: WirValueID = wir_load(ref program, block, slot, "cleared", no_wir_location());
    let cleared_inner: WirValueID = wir_field(ref program, block, cleared, 1, "cleared_inner", no_wir_location());
    block = expect(ref program, function, block, wir_field(ref program, block, cleared_inner, 1, "", no_wir_location()), wir_const_float(ref program, f64, 0.0), 27);
    wir_return(ref program, block, wir_const_int(ref program, i32, UInt128(0U)), no_wir_location());
    return function;
}

func edge_case(ref program: WirModule, length: Int) -> WirFuncID {
    // swap both a bulk-copied array and a padded record across a loop backedge
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let byte: WirTypeID = wir_unsigned_int_type(ref program, 8);
    let word: WirTypeID = wir_unsigned_int_type(ref program, 16);
    let f64: WirTypeID = wir_float_type(ref program, 64);
    let array: WirTypeID = wir_array_type(ref program, byte, UIntSize(length));
    let record: WirTypeID = wir_struct_type(ref program, [byte, f64, word]);
    let function: WirFuncID = wir_add_function(ref program, "edge_" + length, [WirParam(name="choose", type_id=program.bool_type)], i32, false, WirLinkage.Internal, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, function, "entry", []);
    let params: Vector(WirParam) = [WirParam(name="left", type_id=array), WirParam(name="right", type_id=array), WirParam(name="record_left", type_id=record), WirParam(name="record_right", type_id=record), WirParam(name="count", type_id=i32), WirParam(name="expected_left", type_id=byte), WirParam(name="expected_right", type_id=byte), WirParam(name="expected_float", type_id=f64)];
    let header: WirBlockID = wir_add_block(ref program, function, "header", params);
    let body: WirBlockID = wir_add_block(ref program, function, "body", []);
    let exit: WirBlockID = wir_add_block(ref program, function, "exit", []);
    let left_elements: Vector(WirValueID) = [];
    let right_elements: Vector(WirValueID) = [];
    let i = 0;
    while (i < length) {
        left_elements.append(wir_const_int(ref program, byte, UInt128(7U)));
        right_elements.append(wir_const_int(ref program, byte, UInt128(9U)));
        i++;
    }
    let left: WirValueID = wir_array_value(ref program, entry, array, left_elements, "left", no_wir_location());
    let right: WirValueID = wir_array_value(ref program, entry, array, right_elements, "right", no_wir_location());
    let seven: WirValueID = wir_const_int(ref program, byte, UInt128(7U));
    let nine: WirValueID = wir_const_int(ref program, byte, UInt128(9U));
    let fraction: WirValueID = wir_const_float(ref program, f64, 2.5);
    let negative: WirValueID = wir_const_float(ref program, f64, -4.5);
    let left_record: WirValueID = wir_struct_value(ref program, entry, record, [seven, fraction, wir_const_int(ref program, word, UInt128(3000U))], "left_record", no_wir_location());
    let right_record: WirValueID = wir_struct_value(ref program, entry, record, [nine, negative, wir_const_int(ref program, word, UInt128(4000U))], "right_record", no_wir_location());
    let zero: WirValueID = wir_const_int(ref program, i32, UInt128(0U));
    let choose: WirValueID = program.arena.functions[wir_id_index(UInt32(function))].parameters[0];
    wir_append(ref program, entry, WirOpcode.Branch, program.void_type, [choose], [wir_edge(header, [left, right, left_record, right_record, zero, nine, seven, negative]), wir_edge(header, [right, left, right_record, left_record, zero, seven, nine, fraction])], no_wir_location());
    let carried: Vector(WirValueID) = program.arena.blocks[wir_id_index(UInt32(header))].parameters;
    let less: WirValueID = wir_append(ref program, header, WirOpcode.SignedLess, program.bool_type, [carried[4], wir_const_int(ref program, i32, UInt128(5U))], [], no_wir_location());
    wir_append(ref program, header, WirOpcode.Branch, program.void_type, [less], [wir_edge(body, []), wir_edge(exit, [])], no_wir_location());
    let next: WirValueID = wir_binary(ref program, body, WirOpcode.Add, i32, carried[4], wir_const_int(ref program, i32, UInt128(1U)), "next", no_wir_location());
    wir_append(ref program, body, WirOpcode.Jump, program.void_type, [], [wir_edge(header, [carried[1], carried[0], carried[3], carried[2], next, carried[5], carried[6], carried[7]])], no_wir_location());
    let block: WirBlockID = exit;
    let last: WirValueID = wir_const_int(ref program, i32, UInt128(UInt32(length - 1)));
    block = expect(ref program, function, block, wir_index(ref program, block, carried[0], last, "left_last", no_wir_location()), carried[5], 30);
    block = expect(ref program, function, block, wir_index(ref program, block, carried[1], zero, "right_first", no_wir_location()), carried[6], 31);
    block = expect(ref program, function, block, wir_field(ref program, block, carried[2], 0, "record_byte", no_wir_location()), carried[5], 32);
    block = expect(ref program, function, block, wir_field(ref program, block, carried[2], 1, "record_float", no_wir_location()), carried[7], 33);
    block = expect(ref program, function, block, carried[4], wir_const_int(ref program, i32, UInt128(5U)), 34);
    // zero aggregate constants also have to survive staging without an SSA home
    let cleared: WirBlockID = wir_add_block(ref program, function, "cleared", [WirParam(name="value", type_id=array)]);
    wir_append(ref program, block, WirOpcode.Jump, program.void_type, [], [wir_edge(cleared, [wir_const_zero(ref program, array)])], no_wir_location());
    let cleared_value: WirValueID = program.arena.blocks[wir_id_index(UInt32(cleared))].parameters[0];
    block = expect(ref program, function, cleared, wir_index(ref program, cleared, cleared_value, last, "cleared_last", no_wir_location()), wir_const_int(ref program, byte, UInt128(0U)), 35);
    wir_return(ref program, block, zero, no_wir_location());
    return function;
}

func edge_pressure_case(ref program: WirModule) -> WirFuncID {
    // the first staged constant needs a register while all three computed sources are live
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let function: WirFuncID = wir_add_function(ref program, "edge_pressure", [WirParam(name="choose", type_id=program.bool_type)], i32, false, WirLinkage.Internal, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, function, "entry", []);
    let target: WirBlockID = wir_add_block(ref program, function, "target", [WirParam(name="a", type_id=i32), WirParam(name="b", type_id=i32), WirParam(name="c", type_id=i32), WirParam(name="d", type_id=i32), WirParam(name="expected", type_id=i32)]);
    let a: WirValueID = wir_binary(ref program, entry, WirOpcode.Add, i32, wir_const_int(ref program, i32, UInt128(1U)), wir_const_int(ref program, i32, UInt128(2U)), "a", no_wir_location());
    let b: WirValueID = wir_binary(ref program, entry, WirOpcode.Multiply, i32, wir_const_int(ref program, i32, UInt128(3U)), wir_const_int(ref program, i32, UInt128(4U)), "b", no_wir_location());
    let c: WirValueID = wir_binary(ref program, entry, WirOpcode.Subtract, i32, wir_const_int(ref program, i32, UInt128(9U)), wir_const_int(ref program, i32, UInt128(4U)), "c", no_wir_location());
    let choose: WirValueID = program.arena.functions[wir_id_index(UInt32(function))].parameters[0];
    wir_append(ref program, entry, WirOpcode.Branch, program.void_type, [choose], [wir_edge(target, [wir_const_int(ref program, i32, UInt128(11U)), a, b, c, wir_const_int(ref program, i32, UInt128(31U))]), wir_edge(target, [c, b, a, wir_const_int(ref program, i32, UInt128(22U)), wir_const_int(ref program, i32, UInt128(42U))])], no_wir_location());
    let carried: Vector(WirValueID) = program.arena.blocks[wir_id_index(UInt32(target))].parameters;
    let sum: WirValueID = wir_binary(ref program, target, WirOpcode.Add, i32, carried[0], carried[1], "sum_ab", no_wir_location());
    sum = wir_binary(ref program, target, WirOpcode.Add, i32, sum, carried[2], "sum_abc", no_wir_location());
    sum = wir_binary(ref program, target, WirOpcode.Add, i32, sum, carried[3], "sum_all", no_wir_location());
    let block: WirBlockID = expect(ref program, function, target, sum, carried[4], 36);
    wir_return(ref program, block, wir_const_int(ref program, i32, UInt128(0U)), no_wir_location());
    return function;
}

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let cases: Vector(WirFuncID) = [record_case(ref program)];
    let lengths: Vector(Int) = [1, 7, 8, 9, 63, 64, 65, 66, 67, 71, 72, 95, 127, 131, 255];
    let i: Int = 0;
    while (i < lengths.length()) {
        cases.append(array_case(ref program, lengths[i]));
        i++;
    }
    let edge_functions: Vector(WirFuncID) = [edge_case(ref program, 1), edge_case(ref program, 65), edge_case(ref program, 131), edge_pressure_case(ref program)];
    let native: WirFuncID = wir_add_function(ref program, "main", [], i32, false, WirLinkage.Exported, WirABI.White);
    let block: WirBlockID = wir_add_block(ref program, native, "entry", []);
    i = 0;
    while (i < cases.length()) {
        let args: Vector(WirValueID) = [];
        if (i != 0) { args.append(wir_const_int(ref program, i32, UInt128(42U))); }
        let status: WirValueID = wir_call(ref program, block, wir_function_value(program, cases[i]), args, "status", no_wir_location());
        let next: WirBlockID = wir_add_block(ref program, native, "case_next_" + i, []);
        let fail: WirBlockID = wir_add_block(ref program, native, "case_fail_" + i, []);
        let equal: WirValueID = wir_append(ref program, block, WirOpcode.Equal, program.bool_type, [status, wir_const_int(ref program, i32, UInt128(0U))], [], no_wir_location());
        wir_append(ref program, block, WirOpcode.Branch, program.void_type, [equal], [wir_edge(next, []), wir_edge(fail, [])], no_wir_location());
        wir_return(ref program, fail, status, no_wir_location());
        block = next;
        i++;
    }
    i = 0;
    while (i < edge_functions.length() * 2) {
        let status: WirValueID = wir_call(ref program, block, wir_function_value(program, edge_functions[i / 2]), [wir_const_bool(ref program, i % 2 == 0)], "edge_status", no_wir_location());
        let next: WirBlockID = wir_add_block(ref program, native, "edge_next_" + i, []);
        let fail: WirBlockID = wir_add_block(ref program, native, "edge_fail_" + i, []);
        let equal: WirValueID = wir_append(ref program, block, WirOpcode.Equal, program.bool_type, [status, wir_const_int(ref program, i32, UInt128(0U))], [], no_wir_location());
        wir_append(ref program, block, WirOpcode.Branch, program.void_type, [equal], [wir_edge(next, []), wir_edge(fail, [])], no_wir_location());
        wir_return(ref program, fail, status, no_wir_location());
        block = next;
        i++;
    }
    wir_return(ref program, block, wir_const_int(ref program, i32, UInt128(0U)), no_wir_location());
    let exit: WirFuncID = wir_add_function(ref program, "ExitProcess", [WirParam(name="status", type_id=i32)], program.void_type, false, WirLinkage.External, WirABI.System);
    let startup: WirFuncID = wir_add_function(ref program, "mainCRTStartup", [], program.void_type, false, WirLinkage.Exported, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, startup, "entry", []);
    let status: WirValueID = wir_call(ref program, entry, wir_function_value(program, native), [], "status", no_wir_location());
    wir_call(ref program, entry, wir_function_value(program, exit), [status], "", no_wir_location());
    wir_return(ref program, entry, NO_WIR_VALUE, no_wir_location());
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: invalid aggregate test: ", errors[0]);
        return 1;
    }
    let lowered: X86ModuleResult = x86_lower_module(ref program);
    if (lowered.errors.length() != 0) {
        print("FAIL: aggregate lowering: ", lowered.errors[0]);
        return 1;
    }
    let object: Vector(Byte) = coff_object(X86Object(sections=lowered.sections, symbols=lowered.symbols, relocations=lowered.relocations))?;
    catch(err) {
        print("FAIL: aggregate COFF output");
        return 1;
    }
    print("PASS: aggregate snapshots and memory copies");
    print("OBJECT-BEGIN");
    i = 0;
    while (i < object.length()) {
        print(Int(object[i]));
        i++;
    }
    print("OBJECT-END");
    return 0;
}
