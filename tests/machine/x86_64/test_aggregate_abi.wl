// Test: X86_64_AGGREGATE_ABI
// File: tests/machine/x86_64/test_aggregate_abi.wl
// Focus: POD arguments and hidden return pointers, checked against an independent C caller.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import verify_wir from "../../../src/compiler/wir/verify.wl"
import X86Object from "../../../src/compiler/machine/x86_64/model.wl"
import * from "../../../src/compiler/machine/x86_64/lowering.wl"
import coff_object from "../../../src/compiler/machine/x86_64/coff.wl"

func echo(ref program: WirModule, name: String, params: Vector(WirParam), selected: Int, result: WirTypeID) -> WirFuncID {
    let function: WirFuncID = wir_add_function(ref program, name, params, result, false, WirLinkage.Exported, WirABI.C);
    let entry: WirBlockID = wir_add_block(ref program, function, "entry", []);
    let value: WirValueID = program.arena.functions[wir_id_index(UInt32(function))].parameters[selected];
    wir_return(ref program, entry, value, no_wir_location());
    return function;
}

func relay(ref program: WirModule, name: String, qword: WirTypeID, dword: WirTypeID, double_record: WirTypeID, host: WirFuncID, indirect: Bool, twice: Bool) -> Void {
    let signature: WirTypeID = program.arena.functions[wir_id_index(UInt32(host))].type_id;
    let params: Vector(WirParam) = [];
    if (indirect) { params.append(WirParam(name="target", type_id=signature)); }
    params.append(WirParam(name="value", type_id=qword));
    let function: WirFuncID = wir_add_function(ref program, name, params, qword, false, WirLinkage.Exported, WirABI.C);
    let entry: WirBlockID = wir_add_block(ref program, function, "entry", []);
    let values: Vector(WirValueID) = program.arena.functions[wir_id_index(UInt32(function))].parameters;
    let target: WirValueID = wir_function_value(program, host);
    let input: WirValueID = values[0];
    if (indirect) {
        target = values[0];
        input = values[1];
    }
    let number: WirValueID = wir_struct_value(ref program, entry, dword, [wir_const_int(ref program, wir_unsigned_int_type(ref program, 32), UInt128(123456U))], "number", no_wir_location());
    let mask: WirValueID = wir_struct_value(ref program, entry, qword, [wir_const_int(ref program, wir_unsigned_int_type(ref program, 64), UInt128(1311768467463790320UL))], "mask", no_wir_location());
    let fraction: WirValueID = wir_struct_value(ref program, entry, double_record, [wir_const_float(ref program, wir_float_type(ref program, 64), -9.5)], "fraction", no_wir_location());
    let args: Vector(WirValueID) = [input, wir_const_float(ref program, wir_float_type(ref program, 64), 2.5), number, wir_const_float(ref program, wir_float_type(ref program, 32), 1.25), mask, fraction];
    let result: WirValueID = wir_call(ref program, entry, target, args, "first", no_wir_location());
    if (twice) {
        args[0] = result;
        result = wir_call(ref program, entry, target, args, "second", no_wir_location());
    }
    wir_return(ref program, entry, result, no_wir_location());
}

func large_cases(ref program: WirModule, length: Int, qword: WirTypeID, double_record: WirTypeID) -> Void {
    let byte: WirTypeID = wir_unsigned_int_type(ref program, 8);
    let array: WirTypeID = wir_array_type(ref program, byte, UIntSize(length));
    let record: WirTypeID = wir_struct_type(ref program, [array]);
    let params: Vector(WirParam) = [WirParam(name="a", type_id=record), WirParam(name="b", type_id=wir_float_type(ref program, 64)), WirParam(name="c", type_id=qword), WirParam(name="d", type_id=wir_float_type(ref program, 32)), WirParam(name="e", type_id=record), WirParam(name="f", type_id=double_record)];
    echo(ref program, "native_large_" + length, params, 4, record);
    echo(ref program, "native_large_marker_" + length, params, 2, qword);
    echo(ref program, "native_large_float_" + length, params, 1, wir_float_type(ref program, 64));
    let zero: WirFuncID = wir_add_function(ref program, "native_large_zero_" + length, [], record, false, WirLinkage.Exported, WirABI.C);
    let zero_entry: WirBlockID = wir_add_block(ref program, zero, "entry", []);
    wir_return(ref program, zero_entry, wir_const_zero(ref program, record), no_wir_location());
    let host: WirFuncID = wir_add_function(ref program, "host_large_" + length, params, record, false, WirLinkage.External, WirABI.C);
    let signature: WirTypeID = program.arena.functions[wir_id_index(UInt32(host))].type_id;
    let modes: Vector(String) = ["relay", "twice", "indirect", "discard"];
    let i = 0;
    while (i < modes.length()) {
        let incoming: Vector(WirParam) = [];
        if (i == 2) { incoming.append(WirParam(name="target", type_id=signature)); }
        incoming.append(WirParam(name="value", type_id=record));
        let function: WirFuncID = wir_add_function(ref program, "native_large_" + modes[i] + "_" + length, incoming, record, false, WirLinkage.Exported, WirABI.C);
        let entry: WirBlockID = wir_add_block(ref program, function, "entry", []);
        let values: Vector(WirValueID) = program.arena.functions[wir_id_index(UInt32(function))].parameters;
        let input: WirValueID = values[0];
        let target: WirValueID = wir_function_value(program, host);
        if (i == 2) {
            input = values[1];
            target = values[0];
        }
        let number: WirValueID = wir_struct_value(ref program, entry, qword, [wir_const_int(ref program, wir_unsigned_int_type(ref program, 64), UInt128(123UL))], "number", no_wir_location());
        let fraction: WirValueID = wir_struct_value(ref program, entry, double_record, [wir_const_float(ref program, wir_float_type(ref program, 64), -9.5)], "fraction", no_wir_location());
        let args: Vector(WirValueID) = [input, wir_const_float(ref program, wir_float_type(ref program, 64), 2.5), number, wir_const_float(ref program, wir_float_type(ref program, 32), 1.25), input, fraction];
        let result: WirValueID = wir_call(ref program, entry, target, args, "first", no_wir_location());
        if (i == 1) {
            args[0] = result;
            result = wir_call(ref program, entry, target, args, "second", no_wir_location());
        }
        if (i == 3) { result = input; }
        wir_return(ref program, entry, result, no_wir_location());
        i++;
    }
}

func main() -> Int {
    // discarding a large result must still allocate its hidden return destination
    let rejected: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let rejected_byte: WirTypeID = wir_unsigned_int_type(ref rejected, 8);
    let large: WirTypeID = wir_struct_type(ref rejected, [rejected_byte, rejected_byte, rejected_byte]);
    let rejected_function: WirFuncID = wir_add_function(ref rejected, "indirect_result", [], large, false, WirLinkage.Internal, WirABI.C);
    let rejected_entry: WirBlockID = wir_add_block(ref rejected, rejected_function, "entry", []);
    wir_return(ref rejected, rejected_entry, wir_const_zero(ref rejected, large), no_wir_location());
    let rejected_result: X86LoweringResult = x86_lower_function(ref rejected, rejected_function);
    if (rejected_result.errors.length() != 0 || rejected_result.bytes.length() == 0) {
        print("FAIL: indirect aggregate return lowering");
        return 1;
    }
    let discarded: WirFuncID = wir_add_function(ref rejected, "discarded_result", [], rejected.void_type, false, WirLinkage.Internal, WirABI.C);
    let discarded_entry: WirBlockID = wir_add_block(ref rejected, discarded, "entry", []);
    wir_call(ref rejected, discarded_entry, wir_function_value(rejected, rejected_function), [], "unused", no_wir_location());
    wir_return(ref rejected, discarded_entry, NO_WIR_VALUE, no_wir_location());
    rejected_result = x86_lower_function(ref rejected, discarded);
    if (rejected_result.errors.length() != 0 || rejected_result.bytes.length() == 0) {
        print("FAIL: discarded indirect return lowering");
        return 1;
    }
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let f32: WirTypeID = wir_float_type(ref program, 32);
    let f64: WirTypeID = wir_float_type(ref program, 64);
    let fields: Vector(WirTypeID) = [wir_unsigned_int_type(ref program, 8), wir_unsigned_int_type(ref program, 16), wir_unsigned_int_type(ref program, 32), wir_unsigned_int_type(ref program, 64), f32, f64];
    let names: Vector(String) = ["byte", "word", "dword", "qword", "float", "double"];
    let records: Vector(WirTypeID) = [];
    let i = 0;
    while (i < fields.length()) {
        let record: WirTypeID = wir_struct_type(ref program, [fields[i]]);
        records.append(record);
        echo(ref program, "native_" + names[i], [WirParam(name="value", type_id=record)], 0, record);
        i++;
    }
    let mixed: Vector(WirParam) = [WirParam(name="a", type_id=records[0]), WirParam(name="b", type_id=f64), WirParam(name="c", type_id=records[4]), WirParam(name="d", type_id=records[1]), WirParam(name="e", type_id=records[3]), WirParam(name="f", type_id=records[5])];
    echo(ref program, "native_fourth", mixed, 3, records[1]);
    echo(ref program, "native_fifth", mixed, 4, records[3]);
    echo(ref program, "native_sixth", mixed, 5, records[5]);
    let zero: WirFuncID = wir_add_function(ref program, "native_zero", [], records[3], false, WirLinkage.Exported, WirABI.C);
    let zero_entry: WirBlockID = wir_add_block(ref program, zero, "entry", []);
    wir_return(ref program, zero_entry, wir_const_zero(ref program, records[3]), no_wir_location());
    let host: WirFuncID = wir_add_function(ref program, "host_mix", [WirParam(name="a", type_id=records[3]), WirParam(name="b", type_id=f64), WirParam(name="c", type_id=records[2]), WirParam(name="d", type_id=f32), WirParam(name="e", type_id=records[3]), WirParam(name="f", type_id=records[5])], records[3], false, WirLinkage.External, WirABI.C);
    relay(ref program, "native_relay", records[3], records[2], records[5], host, false, false);
    relay(ref program, "native_twice", records[3], records[2], records[5], host, false, true);
    relay(ref program, "native_indirect", records[3], records[2], records[5], host, true, false);
    let lengths: Vector(Int) = [3, 16, 24, 65, 131];
    i = 0;
    while (i < lengths.length()) {
        large_cases(ref program, lengths[i], records[3], records[5]);
        i++;
    }
    let verify: WirFuncID = wir_add_function(ref program, "host_verify", [], i32, false, WirLinkage.External, WirABI.C);
    let exit: WirFuncID = wir_add_function(ref program, "ExitProcess", [WirParam(name="status", type_id=i32)], program.void_type, false, WirLinkage.External, WirABI.System);
    let startup: WirFuncID = wir_add_function(ref program, "mainCRTStartup", [], program.void_type, false, WirLinkage.Exported, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, startup, "entry", []);
    let status: WirValueID = wir_call(ref program, entry, wir_function_value(program, verify), [], "status", no_wir_location());
    wir_call(ref program, entry, wir_function_value(program, exit), [status], "", no_wir_location());
    wir_return(ref program, entry, NO_WIR_VALUE, no_wir_location());
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: aggregate ABI WIR: ", errors[0]);
        return 1;
    }
    let lowered: X86ModuleResult = x86_lower_module(ref program);
    if (lowered.errors.length() != 0) {
        print("FAIL: aggregate ABI lowering: ", lowered.errors[0]);
        return 1;
    }
    let object: Vector(Byte) = coff_object(X86Object(sections=lowered.sections, symbols=lowered.symbols, relocations=lowered.relocations))?;
    catch(err) {
        print("FAIL: aggregate ABI object");
        return 1;
    }
    print("PASS: Win64 aggregate ABI");
    print("OBJECT-BEGIN");
    i = 0;
    while (i < object.length()) {
        print(Int(object[i]));
        i++;
    }
    print("OBJECT-END");
    return 0;
}
