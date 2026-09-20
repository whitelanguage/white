// Test: X86_64_INDIRECT_CALLS
// File: tests/machine/x86_64/test_indirect.wl
// Focus: Call function addresses through parameters, memory, returns, and block edges.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import verify_wir from "../../../src/compiler/wir/verify.wl"
import X86Object, X86Register from "../../../src/compiler/machine/x86_64/model.wl"
import X86CodeBuffer, x86_new_code_buffer, x86_call_register from "../../../src/compiler/machine/x86_64/encoder.wl"
import * from "../../../src/compiler/machine/x86_64/lowering.wl"
import coff_object from "../../../src/compiler/machine/x86_64/coff.wl"

func number(ref program: WirModule, type_id: WirTypeID, value: Int) -> WirValueID {
    return wir_const_int(ref program, type_id, UInt128(UInt32(value)));
}

func check(ref program: WirModule, function: WirFuncID, block: WirBlockID, actual: WirValueID, expected: Int, code: Int) -> WirBlockID {
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let next: WirBlockID = wir_add_block(ref program, function, "next_" + code, []);
    let fail: WirBlockID = wir_add_block(ref program, function, "fail_" + code, []);
    let equal: WirValueID = wir_append(ref program, block, WirOpcode.Equal, program.bool_type, [actual, number(ref program, i32, expected)], [], no_wir_location());
    wir_append(ref program, block, WirOpcode.Branch, program.void_type, [equal], [wir_edge(next, []), wir_edge(fail, [])], no_wir_location());
    wir_return(ref program, fail, number(ref program, i32, code), no_wir_location());
    return next;
}

func main() -> Int {
    let encoded: X86CodeBuffer = x86_new_code_buffer();
    if (!x86_call_register(ref encoded, X86Register.RAX) || !x86_call_register(ref encoded, X86Register.R11) || x86_call_register(ref encoded, X86Register.None) || x86_call_register(ref encoded, X86Register.XMM0)) {
        print("FAIL: invalid indirect call register encoding");
        return 1;
    }
    if (encoded.bytes.length() != 5 || encoded.bytes[0] != Byte(255) || encoded.bytes[1] != Byte(208) || encoded.bytes[2] != Byte(65) || encoded.bytes[3] != Byte(255) || encoded.bytes[4] != Byte(211)) {
        print("FAIL: indirect CALL encoding differs from FF /2");
        return 1;
    }

    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let signature: WirTypeID = wir_function_type(ref program, [i32, i32, i32, i32, i32, i32], i32, false, WirABI.White);
    let params: Vector(WirParam) = [];
    let i: Int = 0;
    while (i < 6) {
        params.append(WirParam(name="p" + i, type_id=i32));
        i++;
    }
    let helper: WirFuncID = wir_add_function(ref program, "digits", params, i32, false, WirLinkage.Internal, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, helper, "entry", []);
    let args: Vector(WirValueID) = program.arena.functions[wir_id_index(UInt32(helper))].parameters;
    let total: WirValueID = args[0];
    let weight: Int = 10;
    i = 1;
    while (i < 6) {
        let term: WirValueID = wir_binary(ref program, entry, WirOpcode.Multiply, i32, args[i], number(ref program, i32, weight), "term", no_wir_location());
        total = wir_binary(ref program, entry, WirOpcode.Add, i32, total, term, "total", no_wir_location());
        weight *= 10;
        i++;
    }
    wir_return(ref program, entry, total, no_wir_location());
    let address: WirValueID = wir_function_value(program, helper);
    let callback: WirGlobalID = wir_add_global(ref program, "callback", signature, wir_const_address(ref program, signature, address, 0L), WirLinkage.Internal, true);

    // the callee is the first parameter; three incoming integers are already on the stack
    let relay_params: Vector(WirParam) = [WirParam(name="target", type_id=signature)];
    i = 0;
    while (i < params.length()) {
        relay_params.append(params[i]);
        i++;
    }
    let relay: WirFuncID = wir_add_function(ref program, "relay", relay_params, i32, false, WirLinkage.Internal, WirABI.White);
    let relay_entry: WirBlockID = wir_add_block(ref program, relay, "entry", []);
    let relay_values: Vector(WirValueID) = program.arena.functions[wir_id_index(UInt32(relay))].parameters;
    let forwarded: Vector(WirValueID) = [];
    i = 1;
    while (i < relay_values.length()) {
        forwarded.append(relay_values[i]);
        i++;
    }
    let relayed: WirValueID = wir_call(ref program, relay_entry, relay_values[0], forwarded, "result", no_wir_location());
    wir_return(ref program, relay_entry, relayed, no_wir_location());

    let factory: WirFuncID = wir_add_function(ref program, "factory", [], signature, false, WirLinkage.Internal, WirABI.White);
    let factory_entry: WirBlockID = wir_add_block(ref program, factory, "entry", []);
    wir_return(ref program, factory_entry, address, no_wir_location());

    let main_id: WirFuncID = wir_add_function(ref program, "main", [], i32, false, WirLinkage.Exported, WirABI.White);
    let block: WirBlockID = wir_add_block(ref program, main_id, "entry", []);
    let slot: WirValueID = wir_stack_alloc(ref program, block, signature, "slot", no_wir_location());
    let numbers: Vector(WirValueID) = [];
    i = 1;
    while (i <= 6) {
        numbers.append(number(ref program, i32, i));
        i++;
    }
    let loaded: WirValueID = wir_load(ref program, block, wir_global_value(program, callback), "callback", no_wir_location());
    let result: WirValueID = wir_call(ref program, block, loaded, numbers, "first", no_wir_location());
    let again: WirValueID = wir_call(ref program, block, loaded, numbers, "second", no_wir_location());
    let combined: WirValueID = wir_binary(ref program, block, WirOpcode.Add, i32, result, again, "combined", no_wir_location());
    block = check(ref program, main_id, block, combined, 1308642, 1);

    let relay_args: Vector(WirValueID) = [address];
    i = 0;
    while (i < numbers.length()) {
        relay_args.append(numbers[i]);
        i++;
    }
    block = check(ref program, main_id, block, wir_call(ref program, block, wir_function_value(program, relay), relay_args, "relayed", no_wir_location()), 654321, 2);
    let returned: WirValueID = wir_call(ref program, block, wir_function_value(program, factory), [], "returned", no_wir_location());
    block = check(ref program, main_id, block, wir_call(ref program, block, returned, numbers, "from_return", no_wir_location()), 654321, 3);

    wir_store(ref program, block, address, slot, no_wir_location());
    let reloaded: WirValueID = wir_load(ref program, block, slot, "reloaded", no_wir_location());
    block = check(ref program, main_id, block, wir_call(ref program, block, reloaded, numbers, "from_stack", no_wir_location()), 654321, 4);

    let merged: WirBlockID = wir_add_block(ref program, main_id, "merged", [WirParam(name="target", type_id=signature)]);
    wir_append(ref program, block, WirOpcode.Jump, program.void_type, [], [wir_edge(merged, [address])], no_wir_location());
    block = merged;
    let target: WirValueID = program.arena.blocks[wir_id_index(UInt32(merged))].parameters[0];
    block = check(ref program, main_id, block, wir_call(ref program, block, target, numbers, "from_edge", no_wir_location()), 654321, 5);

    // computed operands must survive argument setup even if their only use is this call
    let computed: Vector(WirValueID) = [];
    i = 0;
    while (i < numbers.length()) {
        computed.append(wir_binary(ref program, block, WirOpcode.Add, i32, numbers[i], number(ref program, i32, 0), "operand", no_wir_location()));
        i++;
    }
    let live_target: WirValueID = wir_load(ref program, block, wir_global_value(program, callback), "live_target", no_wir_location());
    block = check(ref program, main_id, block, wir_call(ref program, block, live_target, computed, "computed", no_wir_location()), 654321, 6);

    computed = [];
    i = 0;
    while (i < numbers.length()) {
        computed.append(wir_binary(ref program, block, WirOpcode.Add, i32, numbers[i], number(ref program, i32, 0), "direct_operand", no_wir_location()));
        i++;
    }
    block = check(ref program, main_id, block, wir_call(ref program, block, address, computed, "computed_direct", no_wir_location()), 654321, 7);
    let raw_pointer: WirTypeID = wir_pointer_type(ref program, wir_unsigned_int_type(ref program, 8));
    let raw_address: WirValueID = wir_const_address(ref program, raw_pointer, address, 0L);
    block = check(ref program, main_id, block, wir_call_typed(ref program, block, raw_address, signature, numbers, "from_pointer", no_wir_location()), 654321, 8);

    let pid: WirFuncID = wir_add_function(ref program, "GetCurrentProcessId", [], i32, false, WirLinkage.External, WirABI.System);
    let pid_type: WirTypeID = program.arena.functions[wir_id_index(UInt32(pid))].type_id;
    let pid_address: WirValueID = wir_const_address(ref program, pid_type, wir_function_value(program, pid), 0L);
    let pid_value: WirValueID = wir_call(ref program, block, pid_address, [], "pid", no_wir_location());
    let exists: WirValueID = wir_append(ref program, block, WirOpcode.NotEqual, program.bool_type, [pid_value, number(ref program, i32, 0)], [], no_wir_location());
    let ok: WirBlockID = wir_add_block(ref program, main_id, "ok", []);
    let fail: WirBlockID = wir_add_block(ref program, main_id, "fail_pid", []);
    wir_append(ref program, block, WirOpcode.Branch, program.void_type, [exists], [wir_edge(ok, []), wir_edge(fail, [])], no_wir_location());
    wir_return(ref program, fail, number(ref program, i32, 9), no_wir_location());
    wir_return(ref program, ok, number(ref program, i32, 0), no_wir_location());

    let exit_id: WirFuncID = wir_add_function(ref program, "ExitProcess", [WirParam(name="status", type_id=i32)], program.void_type, false, WirLinkage.External, WirABI.System);
    let startup: WirFuncID = wir_add_function(ref program, "mainCRTStartup", [], program.void_type, false, WirLinkage.Exported, WirABI.White);
    let startup_entry: WirBlockID = wir_add_block(ref program, startup, "entry", []);
    let status: WirValueID = wir_call(ref program, startup_entry, wir_function_value(program, main_id), [], "status", no_wir_location());
    wir_call(ref program, startup_entry, wir_const_address(ref program, program.arena.functions[wir_id_index(UInt32(exit_id))].type_id, wir_function_value(program, exit_id), 0L), [status], "", no_wir_location());
    wir_return(ref program, startup_entry, NO_WIR_VALUE, no_wir_location());

    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: invalid indirect call test: ", errors[0]);
        return 1;
    }
    let lowered: X86ModuleResult = x86_lower_module(program);
    if (lowered.errors.length() != 0) {
        print("FAIL: indirect call lowering: ", lowered.errors[0]);
        return 1;
    }
    let object: Vector(Byte) = coff_object(X86Object(sections=lowered.sections, symbols=lowered.symbols, relocations=lowered.relocations))?;
    catch(err) {
        print("FAIL: indirect call COFF output");
        return 1;
    }
    print("PASS: x86_64 indirect calls");
    print("OBJECT-BEGIN");
    i = 0;
    while (i < object.length()) {
        print(Int(object[i]));
        i++;
    }
    print("OBJECT-END");
    return 0;
}
