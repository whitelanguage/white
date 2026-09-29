// Test: X86_64_STACK_ARGS
// File: tests/machine/x86_64/test_stack_args.wl
// Focus: Lower Win64 stack arguments and preserve parameters across calls.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/machine/x86_64/lowering.wl"
import * from "../../../src/compiler/machine/x86_64/coff.wl"

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let sum_type: WirTypeID = wir_function_type(ref program, [int_type, int_type, int_type, int_type, int_type, int_type], int_type, false, WirABI.White);
    let sum_id: WirFuncID = wir_add_function(ref program, "sum_six", [
        WirParam(name="a", type_id=int_type), WirParam(name="b", type_id=int_type),
        WirParam(name="c", type_id=int_type), WirParam(name="d", type_id=int_type),
        WirParam(name="e", type_id=int_type), WirParam(name="f", type_id=int_type)
    ], int_type, false, WirLinkage.Internal, WirABI.White);
    let sum_entry: WirBlockID = wir_add_block(ref program, sum_id, "entry", []);
    let sum_value: WirValueID = program.arena.functions[wir_id_index(UInt32(sum_id))].parameters[0];
    let i: Int = 1;
    while (i < 6) {
        sum_value = wir_binary(ref program, sum_entry, WirOpcode.Add, int_type, sum_value, program.arena.functions[wir_id_index(UInt32(sum_id))].parameters[i], "sum", no_wir_location());
        i += 1;
    }
    wir_return(ref program, sum_entry, sum_value, no_wir_location());

    let diff_id: WirFuncID = wir_add_function(ref program, "difference", [WirParam(name="left", type_id=int_type), WirParam(name="right", type_id=int_type)], int_type, false, WirLinkage.Internal, WirABI.White);
    let diff_entry: WirBlockID = wir_add_block(ref program, diff_id, "entry", []);
    let diff_value: WirValueID = wir_binary(ref program, diff_entry, WirOpcode.Subtract, int_type, program.arena.functions[wir_id_index(UInt32(diff_id))].parameters[0], program.arena.functions[wir_id_index(UInt32(diff_id))].parameters[1], "difference", no_wir_location());
    wir_return(ref program, diff_entry, diff_value, no_wir_location());

    let relay_id: WirFuncID = wir_add_function(ref program, "relay", [WirParam(name="left", type_id=int_type), WirParam(name="right", type_id=int_type)], int_type, false, WirLinkage.Internal, WirABI.White);
    let relay_entry: WirBlockID = wir_add_block(ref program, relay_id, "entry", []);
    let diff_address: WirValueID = program.arena.functions[wir_id_index(UInt32(diff_id))].address;
    let pair_type: WirTypeID = wir_function_type(ref program, [int_type, int_type], int_type, false, WirABI.White);
    let relay_value: WirValueID = wir_call_typed(ref program, relay_entry, diff_address, pair_type, [program.arena.functions[wir_id_index(UInt32(relay_id))].parameters[1], program.arena.functions[wir_id_index(UInt32(relay_id))].parameters[0]], "value", no_wir_location());
    wir_return(ref program, relay_entry, relay_value, no_wir_location());

    let main_id: WirFuncID = wir_add_function(ref program, "main", [], int_type, false, WirLinkage.Exported, WirABI.White);
    let main_entry: WirBlockID = wir_add_block(ref program, main_id, "entry", []);
    let sum_address: WirValueID = program.arena.functions[wir_id_index(UInt32(sum_id))].address;
    let six_sum: WirValueID = wir_call_typed(ref program, main_entry, sum_address, sum_type, [
        wir_const_int(ref program, int_type, UInt128(1U)), wir_const_int(ref program, int_type, UInt128(2U)),
        wir_const_int(ref program, int_type, UInt128(3U)), wir_const_int(ref program, int_type, UInt128(4U)),
        wir_const_int(ref program, int_type, UInt128(5U)), wir_const_int(ref program, int_type, UInt128(6U))
    ], "sum", no_wir_location());
    let relay_address: WirValueID = program.arena.functions[wir_id_index(UInt32(relay_id))].address;
    let difference: WirValueID = wir_call_typed(ref program, main_entry, relay_address, pair_type, [
        wir_const_int(ref program, int_type, UInt128(20U)), wir_const_int(ref program, int_type, UInt128(22U))
    ], "difference", no_wir_location());
    let answer: WirValueID = wir_binary(ref program, main_entry, WirOpcode.Add, int_type, six_sum, difference, "answer", no_wir_location());
    wir_return(ref program, main_entry, answer, no_wir_location());

    let lowered: X86ModuleResult = x86_lower_module(ref program);
    if (lowered.errors.length() != 0) {
        print("FAIL: stack argument lowering failed: ", lowered.errors[0]);
        return 1;
    }
    if (lowered.symbols.length() != 4 || lowered.symbols[0].name != "sum_six" || lowered.symbols[1].name != "difference" || lowered.symbols[2].name != "relay" || lowered.symbols[3].name != "main") {
        print("FAIL: stack argument symbols are incomplete");
        return 1;
    }
    let object: Vector(Byte) = [];
    object = coff_object_for_text_symbols(lowered.bytes, lowered.symbols, lowered.relocations)?;
    catch(err) {
        print("FAIL: stack argument object could not be written");
        return 1;
    }
    if (object.length() == 0) {
        print("FAIL: stack argument object is empty");
        return 1;
    }
    print("PASS: x86_64 stack arguments");
    print("OBJECT-BEGIN");
    let byte_index: Int = 0;
    while (byte_index < object.length()) {
        print(Int(object[byte_index]));
        byte_index += 1;
    }
    print("OBJECT-END");
    return 0;
}
