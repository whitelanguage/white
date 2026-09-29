// Test: X86_64_WIDE_INTEGER
// File: tests/machine/x86_64/test_wide_integer.wl
// Focus: Int128 ABI, arithmetic, bitwise, shifts and comparisons against an independent C host.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import verify_wir from "../../../src/compiler/wir/verify.wl"
import X86Object from "../../../src/compiler/machine/x86_64/model.wl"
import * from "../../../src/compiler/machine/x86_64/lowering.wl"
import coff_object from "../../../src/compiler/machine/x86_64/coff.wl"

func binary(ref program: WirModule, name: String, type_id: WirTypeID, opcode: WirOpcode) -> WirFuncID {
    let function: WirFuncID = wir_add_function(ref program, name, [WirParam(name="left", type_id=type_id), WirParam(name="right", type_id=type_id)], type_id, false, WirLinkage.Exported, WirABI.C);
    let entry: WirBlockID = wir_add_block(ref program, function, "entry", []);
    let parameters: Vector(WirValueID) = program.arena.functions[wir_id_index(UInt32(function))].parameters;
    let result: WirValueID = wir_binary(ref program, entry, opcode, type_id, parameters[0], parameters[1], "result", no_wir_location());
    wir_return(ref program, entry, result, no_wir_location());
    return function;
}

func unary(ref program: WirModule, name: String, type_id: WirTypeID, opcode: WirOpcode) -> WirFuncID {
    let function: WirFuncID = wir_add_function(ref program, name, [WirParam(name="value", type_id=type_id)], type_id, false, WirLinkage.Exported, WirABI.C);
    let entry: WirBlockID = wir_add_block(ref program, function, "entry", []);
    let value: WirValueID = program.arena.functions[wir_id_index(UInt32(function))].parameters[0];
    wir_return(ref program, entry, wir_unary(ref program, entry, opcode, type_id, value, "result", no_wir_location()), no_wir_location());
    return function;
}

func comparison(ref program: WirModule, name: String, type_id: WirTypeID, opcode: WirOpcode) -> WirFuncID {
    let function: WirFuncID = wir_add_function(ref program, name, [WirParam(name="left", type_id=type_id), WirParam(name="right", type_id=type_id)], program.bool_type, false, WirLinkage.Exported, WirABI.C);
    let entry: WirBlockID = wir_add_block(ref program, function, "entry", []);
    let parameters: Vector(WirValueID) = program.arena.functions[wir_id_index(UInt32(function))].parameters;
    let result: WirValueID = wir_binary(ref program, entry, opcode, program.bool_type, parameters[0], parameters[1], "result", no_wir_location());
    wir_return(ref program, entry, result, no_wir_location());
    return function;
}

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let i128: WirTypeID = wir_signed_int_type(ref program, 128);
    let u128: WirTypeID = wir_unsigned_int_type(ref program, 128);
    binary(ref program, "native_add128", u128, WirOpcode.Add);
    binary(ref program, "native_sub128", u128, WirOpcode.Subtract);
    binary(ref program, "native_mul128", u128, WirOpcode.Multiply);
    binary(ref program, "native_and128", u128, WirOpcode.BitAnd);
    binary(ref program, "native_or128", u128, WirOpcode.BitOr);
    binary(ref program, "native_xor128", u128, WirOpcode.BitXor);
    unary(ref program, "native_neg128", i128, WirOpcode.Negate);
    unary(ref program, "native_not128", u128, WirOpcode.Not);
    binary(ref program, "native_shl128", u128, WirOpcode.ShiftLeft);
    binary(ref program, "native_lshr128", u128, WirOpcode.UnsignedShiftRight);
    binary(ref program, "native_ashr128", i128, WirOpcode.SignedShiftRight);
    binary(ref program, "native_udiv128", u128, WirOpcode.UnsignedDivide);
    binary(ref program, "native_urem128", u128, WirOpcode.UnsignedRemainder);
    binary(ref program, "native_sdiv128", i128, WirOpcode.SignedDivide);
    binary(ref program, "native_srem128", i128, WirOpcode.SignedRemainder);
    comparison(ref program, "native_eq128", u128, WirOpcode.Equal);
    comparison(ref program, "native_ne128", u128, WirOpcode.NotEqual);
    comparison(ref program, "native_ult128", u128, WirOpcode.UnsignedLess);
    comparison(ref program, "native_ule128", u128, WirOpcode.UnsignedLessEqual);
    comparison(ref program, "native_ugt128", u128, WirOpcode.UnsignedGreater);
    comparison(ref program, "native_uge128", u128, WirOpcode.UnsignedGreaterEqual);
    comparison(ref program, "native_slt128", i128, WirOpcode.SignedLess);
    comparison(ref program, "native_sle128", i128, WirOpcode.SignedLessEqual);
    comparison(ref program, "native_sgt128", i128, WirOpcode.SignedGreater);
    comparison(ref program, "native_sge128", i128, WirOpcode.SignedGreaterEqual);

    let extended_compare: WirFuncID = wir_add_function(ref program, "native_extend_uge128", [WirParam(name="left", type_id=i32), WirParam(name="right", type_id=i32)], program.bool_type, false, WirLinkage.Exported, WirABI.C);
    let extended_entry: WirBlockID = wir_add_block(ref program, extended_compare, "entry", []);
    let extended_parameters: Vector(WirValueID) = program.arena.functions[wir_id_index(UInt32(extended_compare))].parameters;
    let extended_left: WirValueID = wir_cast(ref program, extended_entry, extended_parameters[0], u128, "left.wide", no_wir_location());
    let extended_right: WirValueID = wir_cast(ref program, extended_entry, extended_parameters[1], u128, "right.wide", no_wir_location());
    let extended_result: WirValueID = wir_binary(ref program, extended_entry, WirOpcode.UnsignedGreaterEqual, program.bool_type, extended_left, extended_right, "result", no_wir_location());
    wir_return(ref program, extended_entry, extended_result, no_wir_location());

    let memory: WirFuncID = wir_add_function(ref program, "native_memory128", [WirParam(name="value", type_id=u128)], u128, false, WirLinkage.Exported, WirABI.C);
    let memory_entry: WirBlockID = wir_add_block(ref program, memory, "entry", []);
    let memory_value: WirValueID = program.arena.functions[wir_id_index(UInt32(memory))].parameters[0];
    let slot: WirValueID = wir_stack_alloc(ref program, memory_entry, u128, "slot", no_wir_location());
    wir_store(ref program, memory_entry, memory_value, slot, no_wir_location());
    wir_return(ref program, memory_entry, wir_load(ref program, memory_entry, slot, "loaded", no_wir_location()), no_wir_location());

    let record: WirTypeID = wir_struct_type(ref program, [wir_unsigned_int_type(ref program, 8), u128]);
    let field: WirFuncID = wir_add_function(ref program, "native_field128", [WirParam(name="value", type_id=u128)], u128, false, WirLinkage.Exported, WirABI.C);
    let field_entry: WirBlockID = wir_add_block(ref program, field, "entry", []);
    let field_value: WirValueID = program.arena.functions[wir_id_index(UInt32(field))].parameters[0];
    let constructed: WirValueID = wir_struct_value(ref program, field_entry, record, [wir_const_int(ref program, wir_unsigned_int_type(ref program, 8), UInt128(7U)), field_value], "record", no_wir_location());
    wir_return(ref program, field_entry, wir_field(ref program, field_entry, constructed, 1, "wide", no_wir_location()), no_wir_location());

    let select: WirFuncID = wir_add_function(ref program, "native_select128", [WirParam(name="condition", type_id=program.bool_type), WirParam(name="left", type_id=u128), WirParam(name="right", type_id=u128)], u128, false, WirLinkage.Exported, WirABI.C);
    let select_entry: WirBlockID = wir_add_block(ref program, select, "entry", []);
    let selected: WirBlockID = wir_add_block(ref program, select, "selected", [WirParam(name="value", type_id=u128)]);
    let select_parameters: Vector(WirValueID) = program.arena.functions[wir_id_index(UInt32(select))].parameters;
    wir_append(ref program, select_entry, WirOpcode.Branch, program.void_type, [select_parameters[0]], [wir_edge(selected, [select_parameters[1]]), wir_edge(selected, [select_parameters[2]])], no_wir_location());
    wir_return(ref program, selected, program.arena.blocks[wir_id_index(UInt32(selected))].parameters[0], no_wir_location());

    let host: WirFuncID = wir_add_function(ref program, "host_add128", [WirParam(name="left", type_id=u128), WirParam(name="right", type_id=u128)], u128, false, WirLinkage.External, WirABI.C);
    let relay: WirFuncID = wir_add_function(ref program, "native_relay128", [WirParam(name="left", type_id=u128), WirParam(name="right", type_id=u128)], u128, false, WirLinkage.Exported, WirABI.C);
    let relay_entry: WirBlockID = wir_add_block(ref program, relay, "entry", []);
    let relay_parameters: Vector(WirValueID) = program.arena.functions[wir_id_index(UInt32(relay))].parameters;
    let sum: WirValueID = wir_call(ref program, relay_entry, wir_function_value(program, host), relay_parameters, "sum", no_wir_location());
    let mask: UInt128 = (UInt128(0xfedcba9876543210UL) << UInt128(64U)) | UInt128(0x0123456789abcdefUL);
    let result: WirValueID = wir_binary(ref program, relay_entry, WirOpcode.BitXor, u128, sum, wir_const_int(ref program, u128, mask), "result", no_wir_location());
    wir_return(ref program, relay_entry, result, no_wir_location());

    let constant: WirFuncID = wir_add_function(ref program, "native_constant128", [], u128, false, WirLinkage.Exported, WirABI.C);
    let constant_entry: WirBlockID = wir_add_block(ref program, constant, "entry", []);
    wir_return(ref program, constant_entry, wir_const_int(ref program, u128, mask), no_wir_location());

    let verify: WirFuncID = wir_add_function(ref program, "host_verify128", [], i32, false, WirLinkage.External, WirABI.C);
    let exit: WirFuncID = wir_add_function(ref program, "ExitProcess", [WirParam(name="status", type_id=i32)], program.void_type, false, WirLinkage.External, WirABI.System);
    let startup: WirFuncID = wir_add_function(ref program, "mainCRTStartup", [], program.void_type, false, WirLinkage.Exported, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, startup, "entry", []);
    let status: WirValueID = wir_call(ref program, entry, wir_function_value(program, verify), [], "status", no_wir_location());
    wir_call(ref program, entry, wir_function_value(program, exit), [status], "", no_wir_location());
    wir_return(ref program, entry, NO_WIR_VALUE, no_wir_location());

    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: wide integer WIR: ", errors[0]);
        return 1;
    }
    let lowered: X86ModuleResult = x86_lower_module(ref program);
    if (lowered.errors.length() != 0) {
        print("FAIL: wide integer lowering: ", lowered.errors[0]);
        return 1;
    }
    let object: Vector(Byte) = coff_object(X86Object(sections=lowered.sections, symbols=lowered.symbols, relocations=lowered.relocations))?;
    catch(err) {
        print("FAIL: wide integer object");
        return 1;
    }
    print("PASS: x86_64 128-bit integer core");
    print("OBJECT-BEGIN");
    let i = 0;
    while (i < object.length()) {
        print(Int(object[i]));
        i++;
    }
    print("OBJECT-END");
    return 0;
}
