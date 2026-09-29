// Test: X86_64_CROSS_BLOCK
// File: tests/machine/x86_64/test_cross_block.wl
// Focus: Preserve dominating SSA values across diamonds, loops, calls, and block order.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import verify_wir from "../../../src/compiler/wir/verify.wl"
import X86Object from "../../../src/compiler/machine/x86_64/model.wl"
import * from "../../../src/compiler/machine/x86_64/lowering.wl"
import coff_object from "../../../src/compiler/machine/x86_64/coff.wl"

func number(ref program: WirModule, type_id: WirTypeID, value: Int) -> WirValueID {
    return wir_const_int(ref program, type_id, UInt128(UInt32(value)));
}

func jump(ref program: WirModule, block: WirBlockID, target: WirBlockID) -> Void {
    wir_append(ref program, block, WirOpcode.Jump, program.void_type, [], [wir_edge(target, [])], no_wir_location());
}

func check(ref program: WirModule, function: WirFuncID, block: WirBlockID, actual: WirValueID, expected: WirValueID, code: Int) -> WirBlockID {
    let next: WirBlockID = wir_add_block(ref program, function, "next_" + code, []);
    let fail: WirBlockID = wir_add_block(ref program, function, "fail_" + code, []);
    let equal: WirValueID = wir_append(ref program, block, WirOpcode.Equal, program.bool_type, [actual, expected], [], no_wir_location());
    wir_append(ref program, block, WirOpcode.Branch, program.void_type, [equal], [wir_edge(next, []), wir_edge(fail, [])], no_wir_location());
    wir_return(ref program, fail, number(ref program, wir_signed_int_type(ref program, 32), code), no_wir_location());
    return next;
}

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let f64: WirTypeID = wir_float_type(ref program, 64);
    let u64: WirTypeID = wir_unsigned_int_type(ref program, 64);
    let pid: WirFuncID = wir_add_function(ref program, "GetCurrentProcessId", [], i32, false, WirLinkage.External, WirABI.System);

    let callback: WirFuncID = wir_add_function(ref program, "callback", [WirParam(name="value", type_id=i32)], i32, false, WirLinkage.Internal, WirABI.White);
    let callback_entry: WirBlockID = wir_add_block(ref program, callback, "entry", []);
    let argument: WirValueID = program.arena.functions[wir_id_index(UInt32(callback))].parameters[0];
    wir_return(ref program, callback_entry, wir_binary(ref program, callback_entry, WirOpcode.Add, i32, argument, number(ref program, i32, 1), "increment", no_wir_location()), no_wir_location());
    let signature: WirTypeID = program.arena.functions[wir_id_index(UInt32(callback))].type_id;
    let callback_global: WirGlobalID = wir_add_global(ref program, "callback_address", signature, wir_const_address(ref program, signature, wir_function_value(program, callback), 0L), WirLinkage.Internal, true);

    // both arms use an entry value; calls force the register cache to be discarded
    let diamond: WirFuncID = wir_add_function(ref program, "diamond", [WirParam(name="choose", type_id=program.bool_type)], i32, false, WirLinkage.Internal, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, diamond, "entry", []);
    let left: WirBlockID = wir_add_block(ref program, diamond, "left", []);
    let right: WirBlockID = wir_add_block(ref program, diamond, "right", []);
    let join: WirBlockID = wir_add_block(ref program, diamond, "join", [WirParam(name="arm", type_id=i32)]);
    let choose: WirValueID = program.arena.functions[wir_id_index(UInt32(diamond))].parameters[0];
    let kept: WirValueID = wir_binary(ref program, entry, WirOpcode.Add, i32, number(ref program, i32, 40), number(ref program, i32, 2), "kept", no_wir_location());
    let floating: WirValueID = wir_binary(ref program, entry, WirOpcode.Add, f64, wir_const_float(ref program, f64, 1.5), wir_const_float(ref program, f64, 2.5), "floating", no_wir_location());
    let target: WirValueID = wir_load(ref program, entry, wir_global_value(program, callback_global), "target", no_wir_location());
    wir_append(ref program, entry, WirOpcode.Branch, program.void_type, [choose], [wir_edge(left, []), wir_edge(right, [])], no_wir_location());
    let arms: Vector(WirBlockID) = [left, right];
    let i: Int = 0;
    while (i < arms.length()) {
        let block: WirBlockID = arms[i];
        wir_call(ref program, block, wir_function_value(program, pid), [], "clobber", no_wir_location());
        let adjusted: WirValueID = wir_call(ref program, block, target, [kept], "adjusted", no_wir_location());
        wir_append(ref program, block, WirOpcode.Jump, program.void_type, [], [wir_edge(join, [adjusted])], no_wir_location());
        i++;
    }
    let block: WirBlockID = join;
    let joined: WirValueID = program.arena.blocks[wir_id_index(UInt32(join))].parameters[0];
    block = check(ref program, diamond, block, joined, number(ref program, i32, 43), 1);
    block = check(ref program, diamond, block, kept, number(ref program, i32, 42), 2);
    let float_bits: WirValueID = wir_append(ref program, block, WirOpcode.Bitcast, u64, [floating], [], no_wir_location());
    block = check(ref program, diamond, block, float_bits, wir_const_int(ref program, u64, UInt128(4616189618054758400UL)), 3);
    wir_return(ref program, block, number(ref program, i32, 0), no_wir_location());

    // the defining block is emitted after its use block, but dominates it in the CFG
    let reordered: WirFuncID = wir_add_function(ref program, "reordered", [], i32, false, WirLinkage.Internal, WirABI.White);
    entry = wir_add_block(ref program, reordered, "entry", []);
    let use: WirBlockID = wir_add_block(ref program, reordered, "use", []);
    let definition: WirBlockID = wir_add_block(ref program, reordered, "definition", []);
    jump(ref program, entry, definition);
    let late: WirValueID = wir_binary(ref program, definition, WirOpcode.Multiply, i32, number(ref program, i32, 6), number(ref program, i32, 7), "late", no_wir_location());
    jump(ref program, definition, use);
    wir_return(ref program, use, late, no_wir_location());

    // each iteration rewrites the same home; latch consumes the current iteration's result
    let loop: WirFuncID = wir_add_function(ref program, "loop", [], i32, false, WirLinkage.Internal, WirABI.White);
    entry = wir_add_block(ref program, loop, "entry", []);
    let header: WirBlockID = wir_add_block(ref program, loop, "header", [WirParam(name="index", type_id=i32)]);
    let body: WirBlockID = wir_add_block(ref program, loop, "body", []);
    let latch: WirBlockID = wir_add_block(ref program, loop, "latch", []);
    let exit: WirBlockID = wir_add_block(ref program, loop, "exit", []);
    let invariant: WirValueID = wir_binary(ref program, entry, WirOpcode.Add, i32, number(ref program, i32, 1), number(ref program, i32, 1), "invariant", no_wir_location());
    wir_append(ref program, entry, WirOpcode.Jump, program.void_type, [], [wir_edge(header, [number(ref program, i32, 0)])], no_wir_location());
    let index: WirValueID = program.arena.blocks[wir_id_index(UInt32(header))].parameters[0];
    let less: WirValueID = wir_append(ref program, header, WirOpcode.SignedLess, program.bool_type, [index, number(ref program, i32, 1000)], [], no_wir_location());
    wir_append(ref program, header, WirOpcode.Branch, program.void_type, [less], [wir_edge(body, []), wir_edge(exit, [])], no_wir_location());
    let next_index: WirValueID = wir_binary(ref program, body, WirOpcode.Add, i32, index, invariant, "next_index", no_wir_location());
    jump(ref program, body, latch);
    wir_call(ref program, latch, wir_function_value(program, pid), [], "clobber", no_wir_location());
    wir_append(ref program, latch, WirOpcode.Jump, program.void_type, [], [wir_edge(header, [next_index])], no_wir_location());
    wir_return(ref program, exit, index, no_wir_location());

    let main_id: WirFuncID = wir_add_function(ref program, "main", [], i32, false, WirLinkage.Exported, WirABI.White);
    block = wir_add_block(ref program, main_id, "entry", []);
    let result: WirValueID = wir_call(ref program, block, wir_function_value(program, diamond), [wir_const_bool(ref program, true)], "left", no_wir_location());
    block = check(ref program, main_id, block, result, number(ref program, i32, 0), 4);
    result = wir_call(ref program, block, wir_function_value(program, diamond), [wir_const_bool(ref program, false)], "right", no_wir_location());
    block = check(ref program, main_id, block, result, number(ref program, i32, 0), 5);
    result = wir_call(ref program, block, wir_function_value(program, reordered), [], "reordered", no_wir_location());
    block = check(ref program, main_id, block, result, number(ref program, i32, 42), 6);
    result = wir_call(ref program, block, wir_function_value(program, loop), [], "loop", no_wir_location());
    block = check(ref program, main_id, block, result, number(ref program, i32, 1000), 7);
    wir_return(ref program, block, number(ref program, i32, 0), no_wir_location());
    let exit_id: WirFuncID = wir_add_function(ref program, "ExitProcess", [WirParam(name="status", type_id=i32)], program.void_type, false, WirLinkage.External, WirABI.System);
    let startup: WirFuncID = wir_add_function(ref program, "mainCRTStartup", [], program.void_type, false, WirLinkage.Exported, WirABI.White);
    let startup_entry: WirBlockID = wir_add_block(ref program, startup, "entry", []);
    let status: WirValueID = wir_call(ref program, startup_entry, wir_function_value(program, main_id), [], "status", no_wir_location());
    wir_call(ref program, startup_entry, wir_function_value(program, exit_id), [status], "", no_wir_location());
    wir_return(ref program, startup_entry, NO_WIR_VALUE, no_wir_location());

    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: cross-block WIR: ", errors[0]);
        return 1;
    }
    let cross: X86ValueFlags = x86_cross_block_values(ref program, x86_block_order(program.arena.functions[wir_id_index(UInt32(reordered))]));
    if (!x86_flag(cross, late)) {
        print("FAIL: cross-block classification depends on block order");
        return 1;
    }
    let lowered: X86ModuleResult = x86_lower_module(ref program);
    if (lowered.errors.length() != 0) {
        print("FAIL: cross-block lowering: ", lowered.errors[0]);
        return 1;
    }
    let object: Vector(Byte) = coff_object(X86Object(sections=lowered.sections, symbols=lowered.symbols, relocations=lowered.relocations))?;
    catch(err) {
        print("FAIL: cross-block COFF output");
        return 1;
    }
    print("PASS: x86_64 cross-block SSA");
    print("OBJECT-BEGIN");
    i = 0;
    while (i < object.length()) {
        print(Int(object[i]));
        i++;
    }
    print("OBJECT-END");
    return 0;
}
