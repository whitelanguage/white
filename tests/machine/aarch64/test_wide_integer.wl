// Test: AARCH64_WIDE_INTEGER_ABI
// File: tests/machine/aarch64/test_wide_integer.wl
// Focus: Pass, return and copy 128-bit integers as AAPCS64 register pairs.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import A64RelocationKind from "../../../src/compiler/machine/aarch64/model.wl"
import * from "../../../src/compiler/machine/aarch64/lowering.wl"


func binary(ref program: WirModule, name: String, type_id: WirTypeID, opcode: WirOpcode) -> Void {
    let function_id: WirFuncID = wir_add_function(ref program, name, [wir_param("left", type_id), wir_param("right", type_id)], type_id, false, WirLinkage.Exported, WirABI.C);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let result: WirValueID = wir_binary(ref program, entry, opcode, type_id, function.parameters[0], function.parameters[1], "result", no_wir_location());
    wir_return(ref program, entry, result, no_wir_location());
}

func unary(ref program: WirModule, name: String, type_id: WirTypeID, opcode: WirOpcode) -> Void {
    let function_id: WirFuncID = wir_add_function(ref program, name, [wir_param("value", type_id)], type_id, false, WirLinkage.Exported, WirABI.C);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let value: WirValueID = program.arena.functions[wir_id_index(UInt32(function_id))].parameters[0];
    let result: WirValueID = wir_unary(ref program, entry, opcode, type_id, value, "result", no_wir_location());
    wir_return(ref program, entry, result, no_wir_location());
}

func comparison(ref program: WirModule, name: String, type_id: WirTypeID, opcode: WirOpcode) -> Void {
    let function_id: WirFuncID = wir_add_function(ref program, name, [wir_param("left", type_id), wir_param("right", type_id)], program.bool_type, false, WirLinkage.Exported, WirABI.C);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let result: WirValueID = wir_binary(ref program, entry, opcode, program.bool_type, function.parameters[0], function.parameters[1], "result", no_wir_location());
    wir_return(ref program, entry, result, no_wir_location());
}

func main() -> Int {
    let program: WirModule = new_wir_module("aarch64-unknown-linux-gnu", 64);
    let i128: WirTypeID = wir_signed_int_type(ref program, 128);
    let u128: WirTypeID = wir_unsigned_int_type(ref program, 128);

    let echo: WirFuncID = wir_add_function(ref program, "echo128", [wir_param("value", u128)], u128, false, WirLinkage.Exported, WirABI.C);
    let echo_entry: WirBlockID = wir_add_block(ref program, echo, "entry", []);
    let echo_value: WirValueID = program.arena.functions[wir_id_index(UInt32(echo))].parameters[0];
    wir_return(ref program, echo_entry, echo_value, no_wir_location());

    let memory: WirFuncID = wir_add_function(ref program, "memory128", [wir_param("value", u128)], u128, false, WirLinkage.Exported, WirABI.C);
    let memory_entry: WirBlockID = wir_add_block(ref program, memory, "entry", []);
    let memory_value: WirValueID = program.arena.functions[wir_id_index(UInt32(memory))].parameters[0];
    let slot: WirValueID = wir_stack_alloc(ref program, memory_entry, u128, "slot", no_wir_location());
    wir_store(ref program, memory_entry, memory_value, slot, no_wir_location());
    let loaded: WirValueID = wir_load(ref program, memory_entry, slot, "loaded", no_wir_location());
    wir_return(ref program, memory_entry, loaded, no_wir_location());

    let relay: WirFuncID = wir_add_function(ref program, "relay128", [wir_param("value", u128)], u128, false, WirLinkage.Exported, WirABI.C);
    let relay_entry: WirBlockID = wir_add_block(ref program, relay, "entry", []);
    let relay_value: WirValueID = program.arena.functions[wir_id_index(UInt32(relay))].parameters[0];
    let call_result: WirValueID = wir_call(ref program, relay_entry, wir_function_value(ref program, echo), [relay_value], "result", no_wir_location());
    wir_return(ref program, relay_entry, call_result, no_wir_location());

    binary(ref program, "add128", u128, WirOpcode.Add);
    binary(ref program, "sub128", u128, WirOpcode.Subtract);
    binary(ref program, "mul128", u128, WirOpcode.Multiply);
    binary(ref program, "and128", u128, WirOpcode.BitAnd);
    binary(ref program, "or128", u128, WirOpcode.BitOr);
    binary(ref program, "xor128", u128, WirOpcode.BitXor);
    binary(ref program, "shl128", u128, WirOpcode.ShiftLeft);
    binary(ref program, "lshr128", u128, WirOpcode.UnsignedShiftRight);
    binary(ref program, "ashr128", i128, WirOpcode.SignedShiftRight);
    binary(ref program, "udiv128", u128, WirOpcode.UnsignedDivide);
    binary(ref program, "urem128", u128, WirOpcode.UnsignedRemainder);
    binary(ref program, "sdiv128", i128, WirOpcode.SignedDivide);
    binary(ref program, "srem128", i128, WirOpcode.SignedRemainder);
    unary(ref program, "neg128", i128, WirOpcode.Negate);
    unary(ref program, "not128", u128, WirOpcode.Not);
    comparison(ref program, "eq128", u128, WirOpcode.Equal);
    comparison(ref program, "ne128", u128, WirOpcode.NotEqual);
    comparison(ref program, "ult128", u128, WirOpcode.UnsignedLess);
    comparison(ref program, "ule128", u128, WirOpcode.UnsignedLessEqual);
    comparison(ref program, "ugt128", u128, WirOpcode.UnsignedGreater);
    comparison(ref program, "uge128", u128, WirOpcode.UnsignedGreaterEqual);
    comparison(ref program, "slt128", i128, WirOpcode.SignedLess);
    comparison(ref program, "sle128", i128, WirOpcode.SignedLessEqual);
    comparison(ref program, "sgt128", i128, WirOpcode.SignedGreater);
    comparison(ref program, "sge128", i128, WirOpcode.SignedGreaterEqual);

    let lowered: A64ModuleResult = a64_lower_module(ref program);
    if (lowered.errors.length() != 0) {
        print("FAIL: AArch64 128-bit ABI lowering failed: ", lowered.errors[0]);
        return 1;
    }
    if (lowered.symbols.length() != 28 || lowered.sections.length() == 0 ||
        lowered.relocations.length() != 1 || lowered.relocations[0].kind != A64RelocationKind.Call26) {
        print("FAIL: AArch64 128-bit functions were not emitted");
        return 1;
    }

    print("PASS: AArch64 128-bit register ABI");
    return 0;
}
