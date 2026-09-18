// Test: X86_64_INTEGER_OPS
// File: tests/machine/x86_64/test_integer_ops.wl
// Focus: Lower 64-bit integer division, remainder, bitwise operations, and variable shifts.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import verify_wir from "../../../src/compiler/wir/verify.wl"
import * from "../../../src/compiler/machine/x86_64/lowering.wl"
import * from "../../../src/compiler/machine/x86_64/coff.wl"

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let i64: WirTypeID = wir_signed_int_type(ref program, 64);
    let calc_id: WirFuncID = wir_add_function(ref program, "calculate", [
        WirParam(name="left", type_id=i64), WirParam(name="right", type_id=i64), WirParam(name="amount", type_id=i64)
    ], i64, false, WirLinkage.Internal, WirABI.White);
    let calc_entry: WirBlockID = wir_add_block(ref program, calc_id, "entry", []);
    let parameters: Vector(WirValueID) = program.arena.functions[wir_id_index(UInt32(calc_id))].parameters;
    let quotient: WirValueID = wir_binary(ref program, calc_entry, WirOpcode.SignedDivide, i64, parameters[0], parameters[1], "quotient", no_wir_location());
    let remainder: WirValueID = wir_binary(ref program, calc_entry, WirOpcode.SignedRemainder, i64, parameters[0], parameters[1], "remainder", no_wir_location());
    let combined: WirValueID = wir_binary(ref program, calc_entry, WirOpcode.BitXor, i64, quotient, remainder, "combined", no_wir_location());
    let shifted: WirValueID = wir_binary(ref program, calc_entry, WirOpcode.ShiftLeft, i64, combined, parameters[2], "shifted", no_wir_location());
    let masked: WirValueID = wir_binary(ref program, calc_entry, WirOpcode.BitAnd, i64, shifted, wir_const_int(ref program, i64, UInt128(255U)), "masked", no_wir_location());
    let negated: WirValueID = wir_unary(ref program, calc_entry, WirOpcode.Negate, i64, masked, "negated", no_wir_location());
    let inverted: WirValueID = wir_unary(ref program, calc_entry, WirOpcode.Not, i64, negated, "inverted", no_wir_location());
    wir_return(ref program, calc_entry, inverted, no_wir_location());

    let main_id: WirFuncID = wir_add_function(ref program, "main", [], i32, false, WirLinkage.Exported, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, main_id, "entry", []);
    let bool_check: WirBlockID = wir_add_block(ref program, main_id, "bool", []);
    let success: WirBlockID = wir_add_block(ref program, main_id, "success", []);
    let failure: WirBlockID = wir_add_block(ref program, main_id, "failure", []);
    let calc_type: WirTypeID = wir_function_type(ref program, [i64, i64, i64], i64, false, WirABI.White);
    let result: WirValueID = wir_call_typed(ref program, entry, program.arena.functions[wir_id_index(UInt32(calc_id))].address, calc_type, [
        wir_const_int(ref program, i64, UInt128(100U)), wir_const_int(ref program, i64, UInt128(7U)), wir_const_int(ref program, i64, UInt128(2U))
    ], "result", no_wir_location());
    let condition: WirValueID = wir_append(ref program, entry, WirOpcode.Equal, program.bool_type, [result, wir_const_int(ref program, i64, UInt128(47U))], [], no_wir_location());
    wir_append(ref program, entry, WirOpcode.Branch, program.void_type, [condition], [wir_edge(bool_check, []), wir_edge(failure, [])], no_wir_location());
    let loaded_condition: WirValueID = wir_append(ref program, bool_check, WirOpcode.Equal, program.bool_type, [wir_const_int(ref program, i32, UInt128(1U)), wir_const_int(ref program, i32, UInt128(1U))], [], no_wir_location());
    let inverted_condition: WirValueID = wir_unary(ref program, bool_check, WirOpcode.Not, program.bool_type, loaded_condition, "inverted", no_wir_location());
    wir_append(ref program, bool_check, WirOpcode.Branch, program.void_type, [inverted_condition], [wir_edge(failure, []), wir_edge(success, [])], no_wir_location());
    wir_return(ref program, success, wir_const_int(ref program, i32, UInt128(0U)), no_wir_location());
    wir_return(ref program, failure, wir_const_int(ref program, i32, UInt128(1U)), no_wir_location());

    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: invalid integer test WIR: ", errors[0]);
        return 1;
    }
    let lowered: X86ModuleResult = x86_lower_module(program);
    if (lowered.errors.length() != 0) {
        print("FAIL: x86_64 integer operation lowering failed: ", lowered.errors[0]);
        return 1;
    }
    let object: Vector(Byte) = coff_object_for_text_symbols(lowered.bytes, lowered.symbols, lowered.relocations)?;
    catch(err) {
        print("FAIL: could not write integer operation test object");
        return 1;
    }
    print("PASS: x86_64 integer operations");
    print("OBJECT-BEGIN");
    let i: Int = 0;
    while (i < object.length()) {
        print(Int(object[i]));
        i += 1;
    }
    print("OBJECT-END");
    return 0;
}
