// Test: X86_64_FLOAT
// File: tests/machine/x86_64/test_float.wl
// Focus: Execute SSE scalar arithmetic and mixed Win64 calls without a CRT.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import verify_wir from "../../../src/compiler/wir/verify.wl"
import X86Object, X86Register from "../../../src/compiler/machine/x86_64/model.wl"
import X86CodeBuffer, x86_new_code_buffer from "../../../src/compiler/machine/x86_64/encoder.wl"
import * from "../../../src/compiler/machine/x86_64/sse.wl"
import * from "../../../src/compiler/machine/x86_64/lowering.wl"
import coff_object from "../../../src/compiler/machine/x86_64/coff.wl"

func check_carry(ref program: WirModule, function: WirFuncID, block: WirBlockID, actual: WirValueID, expected: WirValueID, code: Int, carry: Vector(WirValueID)) -> WirBlockID {
    let params: Vector(WirParam) = [];
    let i: Int = 0;
    while (i < carry.length()) {
        params.append(WirParam(name="kept_" + i, type_id=program.arena.values[wir_id_index(UInt32(carry[i]))].type_id));
        i++;
    }
    let next: WirBlockID = wir_add_block(ref program, function, "next_" + code, params);
    let fail: WirBlockID = wir_add_block(ref program, function, "fail_" + code, []);
    let equal: WirValueID = wir_append(ref program, block, WirOpcode.Equal, program.bool_type, [actual, expected], [], no_wir_location());
    wir_append(ref program, block, WirOpcode.Branch, program.void_type, [equal], [wir_edge(next, carry), wir_edge(fail, [])], no_wir_location());
    let signature: WirType = program.arena.types[wir_id_index(UInt32(program.arena.functions[wir_id_index(UInt32(function))].type_id))];
    if (program.arena.types[wir_id_index(UInt32(signature.result))].kind == WirTypeKind.FloatType) {
        wir_return(ref program, fail, wir_const_float(ref program, signature.result, Float(0 - code)), no_wir_location());
    } else {
        wir_return(ref program, fail, wir_const_int(ref program, signature.result, UInt128(UInt32(code))), no_wir_location());
    }
    return next;
}

func check(ref program: WirModule, function: WirFuncID, block: WirBlockID, actual: WirValueID, expected: WirValueID, code: Int) -> WirBlockID {
    return check_carry(ref program, function, block, actual, expected, code, []);
}

func bits(ref program: WirModule, block: WirBlockID, value: WirValueID, integer: WirTypeID) -> WirValueID {
    return wir_append(ref program, block, WirOpcode.Bitcast, integer, [value], [], no_wir_location());
}

func check_float_carry(ref program: WirModule, function: WirFuncID, block: WirBlockID, value: WirValueID, expected: Float, code: Int, carry: Vector(WirValueID)) -> WirBlockID {
    let type_id: WirTypeID = program.arena.values[wir_id_index(UInt32(value))].type_id;
    let type: WirType = program.arena.types[wir_id_index(UInt32(type_id))];
    let integer: WirTypeID = wir_unsigned_int_type(ref program, type.bits);
    let constant: WirValueID = wir_const_float(ref program, type_id, expected);
    let raw: UInt64 = program.arena.values[wir_id_index(UInt32(constant))].float_bits;
    return check_carry(ref program, function, block, bits(ref program, block, value, integer), wir_const_int(ref program, integer, UInt128(raw)), code, carry);
}

func check_float(ref program: WirModule, function: WirFuncID, block: WirBlockID, value: WirValueID, expected: Float, code: Int) -> WirBlockID {
    return check_float_carry(ref program, function, block, value, expected, code, []);
}

func main() -> Int {
    let encoded: X86CodeBuffer = x86_new_code_buffer();
    if (!x86_sse_register(ref encoded, 88, X86Register.XMM12, X86Register.XMM15, 8) || encoded.bytes.length() != 5 || encoded.bytes[0] != Byte(242) || encoded.bytes[1] != Byte(69) || encoded.bytes[4] != Byte(231)) {
        print("FAIL: SSE extended register encoding");
        return 1;
    }
    if (!x86_sse_memory(ref encoded, 16, X86Register.XMM12, X86Register.R12, 16, 4) || encoded.bytes.length() != 15 || encoded.bytes[5] != Byte(243) || encoded.bytes[6] != Byte(69) || encoded.bytes[9] != Byte(164) || encoded.bytes[10] != Byte(36)) {
        print("FAIL: SSE extended base and SIB encoding");
        return 1;
    }
    if (x86_sse_register(ref encoded, 88, X86Register.RAX, X86Register.XMM0, 8) || x86_sse_memory(ref encoded, 16, X86Register.XMM0, X86Register.RAX, 0, 2)) {
        print("FAIL: SSE encoder accepted invalid operands");
        return 1;
    }

    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let u32: WirTypeID = wir_unsigned_int_type(ref program, 32);
    let u64: WirTypeID = wir_unsigned_int_type(ref program, 64);
    let f32: WirTypeID = wir_float_type(ref program, 32);
    let f64: WirTypeID = wir_float_type(ref program, 64);
    let params: Vector(WirParam) = [WirParam(name="a", type_id=i32), WirParam(name="b", type_id=f64), WirParam(name="c", type_id=i32), WirParam(name="d", type_id=f32), WirParam(name="e", type_id=f64), WirParam(name="f", type_id=f32)];
    let mixed: WirFuncID = wir_add_function(ref program, "mixed", params, f64, false, WirLinkage.Exported, WirABI.White);
    let block: WirBlockID = wir_add_block(ref program, mixed, "entry", []);
    let values: Vector(WirValueID) = program.arena.functions[wir_id_index(UInt32(mixed))].parameters;
    block = check(ref program, mixed, block, values[0], wir_const_int(ref program, i32, UInt128(11U)), 1);
    block = check_float(ref program, mixed, block, values[1], 1.5, 2);
    block = check(ref program, mixed, block, values[2], wir_const_int(ref program, i32, UInt128(22U)), 3);
    block = check_float(ref program, mixed, block, values[3], 2.25, 4);
    block = check_float(ref program, mixed, block, values[4], 3.5, 5);
    block = check_float(ref program, mixed, block, values[5], 4.25, 6);
    let sum: WirValueID = wir_binary(ref program, block, WirOpcode.Add, f64, values[1], values[4], "sum", no_wir_location());
    let widened: WirValueID = wir_append(ref program, block, WirOpcode.FloatExtend, f64, [values[3]], [], no_wir_location());
    sum = wir_binary(ref program, block, WirOpcode.Add, f64, sum, widened, "sum", no_wir_location());
    widened = wir_append(ref program, block, WirOpcode.FloatExtend, f64, [values[5]], [], no_wir_location());
    sum = wir_binary(ref program, block, WirOpcode.Add, f64, sum, widened, "sum", no_wir_location());
    wir_return(ref program, block, sum, no_wir_location());

    let relay: WirFuncID = wir_add_function(ref program, "relay", params, f64, false, WirLinkage.Internal, WirABI.White);
    let relay_entry: WirBlockID = wir_add_block(ref program, relay, "entry", []);
    let relayed: WirValueID = wir_call(ref program, relay_entry, wir_function_value(program, mixed), program.arena.functions[wir_id_index(UInt32(relay))].parameters, "relayed", no_wir_location());
    wir_return(ref program, relay_entry, relayed, no_wir_location());

    let scalar: WirFuncID = wir_add_function(ref program, "scalar", [WirParam(name="value", type_id=f32)], f32, false, WirLinkage.Exported, WirABI.White);
    let scalar_entry: WirBlockID = wir_add_block(ref program, scalar, "entry", []);
    let scalar_parameter: WirValueID = program.arena.functions[wir_id_index(UInt32(scalar))].parameters[0];
    wir_return(ref program, scalar_entry, wir_binary(ref program, scalar_entry, WirOpcode.Add, f32, scalar_parameter, scalar_parameter, "doubled", no_wir_location()), no_wir_location());

    let callback_type: WirTypeID = program.arena.functions[wir_id_index(UInt32(mixed))].type_id;
    let callback: WirGlobalID = wir_add_global(ref program, "mixed_callback", callback_type, wir_const_address(ref program, callback_type, wir_function_value(program, mixed), 0L), WirLinkage.Internal, true);
    let storage: WirGlobalID = wir_add_global(ref program, "float_storage", f64, wir_const_float_bits(ref program, f64, 9223372036854775808UL), WirLinkage.Internal, false);
    let main_id: WirFuncID = wir_add_function(ref program, "main", [], i32, false, WirLinkage.Exported, WirABI.White);
    block = wir_add_block(ref program, main_id, "entry", []);
    let slot: WirValueID = wir_stack_alloc(ref program, block, f32, "float_slot", no_wir_location());
    let arguments: Vector(WirValueID) = [wir_const_int(ref program, i32, UInt128(11U)), wir_const_float(ref program, f64, 1.5), wir_const_int(ref program, i32, UInt128(22U)), wir_const_float(ref program, f32, 2.25), wir_const_float(ref program, f64, 3.5), wir_const_float(ref program, f32, 4.25)];
    let first: WirValueID = wir_call(ref program, block, wir_function_value(program, relay), arguments, "first", no_wir_location());
    let target: WirValueID = wir_load(ref program, block, wir_global_value(program, callback), "target", no_wir_location());
    let second: WirValueID = wir_call(ref program, block, target, arguments, "second", no_wir_location());
    sum = wir_binary(ref program, block, WirOpcode.Add, f64, first, second, "sum", no_wir_location());
    block = check_float(ref program, main_id, block, sum, 23.0, 1);

    let sizes: Vector(WirTypeID) = [f32, f64];
    let i: Int = 0;
    while (i < sizes.length()) {
        let type_id: WirTypeID = sizes[i];
        let value: WirValueID = wir_binary(ref program, block, WirOpcode.Add, type_id, wir_const_float(ref program, type_id, 2.5), wir_const_float(ref program, type_id, 1.5), "add", no_wir_location());
        let product: WirValueID = wir_binary(ref program, block, WirOpcode.Multiply, type_id, value, wir_const_float(ref program, type_id, 2.0), "multiply", no_wir_location());
        let difference: WirValueID = wir_binary(ref program, block, WirOpcode.Subtract, type_id, product, wir_const_float(ref program, type_id, 1.0), "subtract", no_wir_location());
        let quotient: WirValueID = wir_binary(ref program, block, WirOpcode.FloatDivide, type_id, difference, wir_const_float(ref program, type_id, 2.0), "divide", no_wir_location());
        block = check_float(ref program, main_id, block, quotient, 3.5, 2 + i * 2);
        block = check_float(ref program, main_id, block, value, 4.0, 3 + i * 2);
        i++;
    }

    let raw_storage: WirValueID = wir_global_value(program, storage);
    block = check(ref program, main_id, block, bits(ref program, block, wir_load(ref program, block, raw_storage, "negative_zero", no_wir_location()), u64), wir_const_int(ref program, u64, UInt128(9223372036854775808UL)), 6);
    let nan: WirValueID = wir_const_float_bits(ref program, f64, 9221120237041095220UL);
    wir_store(ref program, block, nan, raw_storage, no_wir_location());
    block = check(ref program, main_id, block, bits(ref program, block, wir_load(ref program, block, raw_storage, "nan_payload", no_wir_location()), u64), wir_const_int(ref program, u64, UInt128(9221120237041095220UL)), 7);
    wir_store(ref program, block, wir_const_float(ref program, f32, 2.5), slot, no_wir_location());
    let loaded: WirValueID = wir_load(ref program, block, slot, "loaded", no_wir_location());
    widened = wir_append(ref program, block, WirOpcode.FloatExtend, f64, [loaded], [], no_wir_location());
    let narrowed: WirValueID = wir_append(ref program, block, WirOpcode.FloatTruncate, f32, [widened], [], no_wir_location());
    block = check_float(ref program, main_id, block, narrowed, 2.5, 8);
    block = check_float(ref program, main_id, block, loaded, 2.5, 9);

    let converted: WirValueID = wir_append(ref program, block, WirOpcode.Bitcast, f32, [wir_const_int(ref program, u32, UInt128(1077936128U))], [], no_wir_location());
    block = check_float(ref program, main_id, block, converted, 3.0, 10);
    let infinity: WirValueID = wir_binary(ref program, block, WirOpcode.FloatDivide, f64, wir_const_float(ref program, f64, 1.0), wir_const_float(ref program, f64, 0.0), "infinity", no_wir_location());
    block = check(ref program, main_id, block, bits(ref program, block, infinity, u64), wir_const_int(ref program, u64, UInt128(9218868437227405312UL)), 11);
    let merged: WirBlockID = wir_add_block(ref program, main_id, "merged", [WirParam(name="value", type_id=f64)]);
    wir_append(ref program, block, WirOpcode.Jump, program.void_type, [], [wir_edge(merged, [wir_const_float(ref program, f64, 4.5)])], no_wir_location());
    block = merged;
    block = check_float(ref program, main_id, block, program.arena.blocks[wir_id_index(UInt32(merged))].parameters[0], 4.5, 12);

    // Clang supplies these functions and calls back into the emitted machine code
    let host: WirFuncID = wir_add_function(ref program, "host_mix", params, f64, false, WirLinkage.External, WirABI.C);
    block = check_float(ref program, main_id, block, wir_call(ref program, block, wir_function_value(program, host), arguments, "host_mix", no_wir_location()), 464476.0, 13);
    let host_float: WirFuncID = wir_add_function(ref program, "host_float", [WirParam(name="a", type_id=f32), WirParam(name="b", type_id=f64), WirParam(name="c", type_id=f32), WirParam(name="d", type_id=f64), WirParam(name="e", type_id=f32)], f32, false, WirLinkage.External, WirABI.C);
    let float_args: Vector(WirValueID) = [wir_const_float(ref program, f32, 1.0), wir_const_float(ref program, f64, 2.0), wir_const_float(ref program, f32, 3.0), wir_const_float(ref program, f64, 4.0), wir_const_float(ref program, f32, 5.0)];
    block = check_float(ref program, main_id, block, wir_call(ref program, block, wir_function_value(program, host_float), float_args, "host_float", no_wir_location()), 15.0, 14);
    let roundtrip: WirFuncID = wir_add_function(ref program, "host_roundtrip", [], i32, false, WirLinkage.External, WirABI.C);
    block = check(ref program, main_id, block, wir_call(ref program, block, wir_function_value(program, roundtrip), [], "roundtrip", no_wir_location()), wir_const_int(ref program, i32, UInt128(0U)), 15);
    wir_return(ref program, block, wir_const_int(ref program, i32, UInt128(0U)), no_wir_location());

    let exit_id: WirFuncID = wir_add_function(ref program, "ExitProcess", [WirParam(name="status", type_id=i32)], program.void_type, false, WirLinkage.External, WirABI.System);
    let startup: WirFuncID = wir_add_function(ref program, "mainCRTStartup", [], program.void_type, false, WirLinkage.Exported, WirABI.White);
    let startup_entry: WirBlockID = wir_add_block(ref program, startup, "entry", []);
    let status: WirValueID = wir_call(ref program, startup_entry, wir_function_value(program, main_id), [], "status", no_wir_location());
    wir_call(ref program, startup_entry, wir_function_value(program, exit_id), [status], "", no_wir_location());
    wir_return(ref program, startup_entry, NO_WIR_VALUE, no_wir_location());
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: invalid floating test: ", errors[0]);
        return 1;
    }
    let lowered: X86ModuleResult = x86_lower_module(program);
    if (lowered.errors.length() != 0) {
        print("FAIL: floating lowering: ", lowered.errors[0]);
        return 1;
    }
    let object: Vector(Byte) = coff_object(X86Object(sections=lowered.sections, symbols=lowered.symbols, relocations=lowered.relocations))?;
    catch(err) {
        print("FAIL: floating COFF output");
        return 1;
    }
    print("PASS: x86_64 floating arithmetic and calls");
    print("OBJECT-BEGIN");
    i = 0;
    while (i < object.length()) {
        print(Int(object[i]));
        i++;
    }
    print("OBJECT-END");
    return 0;
}
