// Test: X86_64_EDGE_COPIES
// File: tests/machine/x86_64/test_edges.wl
// Focus: Execute forward joins, duplicate arguments and cyclic register copies.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import verify_wir from "../../../src/compiler/wir/verify.wl"
import * from "../../../src/compiler/machine/x86_64/model.wl"
import * from "../../../src/compiler/machine/x86_64/encoder.wl"
import * from "../../../src/compiler/machine/x86_64/allocator.wl"
import * from "../../../src/compiler/machine/x86_64/lowering.wl"
import x86_repair_edge, X86EdgeCopy from "../../../src/compiler/machine/x86_64/edges.wl"
import x86_block_order, x86_mark_edge_registers, x86_mark_return_registers from "../../../src/compiler/machine/x86_64/flow.wl"
import x86_store_scalar from "../../../src/compiler/machine/x86_64/memory.wl"
import x86_lower_module from "../../../src/compiler/machine/x86_64/module.wl"
import coff_object from "../../../src/compiler/machine/x86_64/coff.wl"

func number(ref program: WirModule, value: Int) -> WirValueID {
    return wir_const_int(ref program, wir_signed_int_type(ref program, 32), UInt128(UInt32(value)));
}

func check(ref program: WirModule, function: WirFuncID, block: WirBlockID, value: WirValueID, expected: Int) -> WirBlockID {
    let next: WirBlockID = wir_add_block(ref program, function, "ok_" + expected, []);
    let fail: WirBlockID = wir_add_block(ref program, function, "fail_" + expected, []);
    let equal: WirValueID = wir_binary(ref program, block, WirOpcode.Equal, program.bool_type, value, number(ref program, expected), "equal", no_wir_location());
    wir_append(ref program, block, WirOpcode.Branch, program.void_type, [equal], [wir_edge(next, []), wir_edge(fail, [])], no_wir_location());
    wir_return(ref program, fail, number(ref program, 1), no_wir_location());
    return next;
}

func raw_cycle() -> X86CodeBuffer {
    // force a three-register cycle independently of allocator preferences.
    // The stack copies contain the desired destination values before repair.
    let code: X86CodeBuffer = x86_new_code_buffer();
    x86_frame_enter(ref code, 32);
    x86_mov_register_imm32(ref code, X86Register.RAX, 10U);
    x86_mov_register_imm32(ref code, X86Register.R10, 20U);
    x86_mov_register_imm32(ref code, X86Register.R11, 30U);
    x86_store_scalar(ref code, X86Register.R10, X86Register.RBP, -8, 4);
    x86_store_scalar(ref code, X86Register.R11, X86Register.RBP, -16, 4);
    x86_store_scalar(ref code, X86Register.RAX, X86Register.RBP, -24, 4);
    let copies: Vector(X86EdgeCopy) = [
        X86EdgeCopy(destination=X86Register.RAX, source=X86Register.R10, offset=-8, size=4, signed=true),
        X86EdgeCopy(destination=X86Register.R10, source=X86Register.R11, offset=-16, size=4, signed=true),
        X86EdgeCopy(destination=X86Register.R11, source=X86Register.RAX, offset=-24, size=4, signed=true)
    ];
    let message: String = x86_repair_edge(copies, ref code);
    if (message.length() != 0) {
        print("FAIL: edge cycle: ", message);
        return x86_new_code_buffer();
    }
    x86_multiply_imm32(ref code, X86Register.RAX, 2U, false);
    x86_multiply_imm32(ref code, X86Register.R10, 3U, false);
    x86_add_register32(ref code, X86Register.RAX, X86Register.R10);
    x86_add_register32(ref code, X86Register.RAX, X86Register.R11);
    x86_frame_leave(ref code);
    x86_return(ref code);
    return code;
}

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let f64: WirTypeID = wir_float_type(ref program, 64);
    let pid: WirFuncID = wir_add_function(ref program, "GetCurrentProcessId", [], i32, false, WirLinkage.External, WirABI.System);
    let cycle: WirFuncID = wir_add_function(ref program, "raw_cycle", [], i32, false, WirLinkage.External, WirABI.System);
    let test: WirFuncID = wir_add_function(ref program, "choose", [WirParam(name="choose", type_id=program.bool_type)], i32, false, WirLinkage.Internal, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, test, "entry", []);
    let params: Vector(WirParam) = [WirParam(name="a", type_id=i32), WirParam(name="b", type_id=i32), WirParam(name="c", type_id=i32), WirParam(name="x", type_id=f64), WirParam(name="y", type_id=f64)];
    let values: WirBlockID = wir_add_block(ref program, test, "values", params);
    let join: WirBlockID = wir_add_block(ref program, test, "join", params);
    let initial: Vector(WirValueID) = [number(ref program, 10), number(ref program, 20), number(ref program, 30), wir_const_float(ref program, f64, 1.5), wir_const_float(ref program, f64, 2.5)];
    wir_append(ref program, entry, WirOpcode.Jump, program.void_type, [], [wir_edge(values, initial)], no_wir_location());
    let p: Vector(WirValueID) = program.arena.blocks[wir_id_index(UInt32(values))].parameters;
    let cond: WirValueID = program.arena.functions[wir_id_index(UInt32(test))].parameters[0];
    // both branch arms have the same target, but carry different permutations.
    wir_append(ref program, values, WirOpcode.Branch, program.void_type, [cond], [wir_edge(join, [p[1], p[2], p[0], p[4], p[3]]), wir_edge(join, [p[0], p[0], p[2], p[3], p[3]])], no_wir_location());
    let q: Vector(WirValueID) = program.arena.blocks[wir_id_index(UInt32(join))].parameters;
    let sum: WirValueID = wir_binary(ref program, join, WirOpcode.Multiply, i32, q[0], number(ref program, 10000), "a", no_wir_location());
    let b: WirValueID = wir_binary(ref program, join, WirOpcode.Multiply, i32, q[1], number(ref program, 100), "b", no_wir_location());
    sum = wir_binary(ref program, join, WirOpcode.Add, i32, sum, b, "ab", no_wir_location());
    sum = wir_binary(ref program, join, WirOpcode.Add, i32, sum, q[2], "abc", no_wir_location());
    let x: WirValueID = wir_binary(ref program, join, WirOpcode.Multiply, f64, q[3], wir_const_float(ref program, f64, 10.0), "x", no_wir_location());
    sum = wir_binary(ref program, join, WirOpcode.Add, i32, sum, wir_cast(ref program, join, x, i32, "ix", no_wir_location()), "with_x", no_wir_location());
    sum = wir_binary(ref program, join, WirOpcode.Add, i32, sum, wir_cast(ref program, join, q[4], i32, "iy", no_wir_location()), "with_y", no_wir_location());
    // first consume the repaired registers, then force a reload of a parameter.
    wir_call(ref program, join, wir_function_value(ref program, pid), [], "clobber", no_wir_location());
    sum = wir_binary(ref program, join, WirOpcode.Add, i32, sum, q[2], "after_call", no_wir_location());
    wir_return(ref program, join, sum, no_wir_location());

    let order: Vector(WirBlockID) = x86_block_order(program.arena.functions[wir_id_index(UInt32(test))]);
    let uses: X86UseTable = x86_collect_uses(ref program, order);
    x86_mark_return_registers(ref program, order, ref uses);
    x86_mark_edge_registers(ref program, order, ref uses);
    if (x86_incoming_register(ref uses, q[0]) == X86Register.None || x86_incoming_register(ref uses, q[3]) == X86Register.None) {
        print("FAIL: scalar join did not receive entry registers");
        return 1;
    }

    let main_id: WirFuncID = wir_add_function(ref program, "main", [], i32, false, WirLinkage.Exported, WirABI.White);
    let block: WirBlockID = wir_add_block(ref program, main_id, "entry", []);
    let result: WirValueID = wir_call(ref program, block, wir_function_value(ref program, test), [wir_const_bool(ref program, true)], "left", no_wir_location());
    block = check(ref program, main_id, block, result, 203046);
    result = wir_call(ref program, block, wir_function_value(ref program, test), [wir_const_bool(ref program, false)], "right", no_wir_location());
    block = check(ref program, main_id, block, result, 101076);
    result = wir_call(ref program, block, wir_function_value(ref program, cycle), [], "cycle", no_wir_location());
    block = check(ref program, main_id, block, result, 140);
    wir_return(ref program, block, number(ref program, 0), no_wir_location());
    let exit_id: WirFuncID = wir_add_function(ref program, "ExitProcess", [WirParam(name="status", type_id=i32)], program.void_type, false, WirLinkage.External, WirABI.System);
    let startup: WirFuncID = wir_add_function(ref program, "mainCRTStartup", [], program.void_type, false, WirLinkage.Exported, WirABI.White);
    let start: WirBlockID = wir_add_block(ref program, startup, "entry", []);
    result = wir_call(ref program, start, wir_function_value(ref program, main_id), [], "status", no_wir_location());
    wir_call(ref program, start, wir_function_value(ref program, exit_id), [result], "", no_wir_location());
    wir_return(ref program, start, NO_WIR_VALUE, no_wir_location());

    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: edge WIR: ", errors[0]);
        return 1;
    }
    let lowered: X86ModuleResult = x86_lower_module(ref program);
    if (lowered.errors.length() != 0) {
        print("FAIL: edge lowering: ", lowered.errors[0]);
        return 1;
    }
    let code: X86CodeBuffer = raw_cycle();
    if (code.bytes.length() == 0) { return 1; }
    lowered.sections.append(X86CodeSection(name=".edge", bytes=code.bytes, alignment=16, executable=true, writable=false));
    let i = 0;
    while (i < lowered.symbols.length()) {
        if (lowered.symbols[i].name == "raw_cycle") {
            lowered.symbols[i] = X86Symbol(name="raw_cycle", section=".edge", offset=0U, external=true);
        }
        i++;
    }
    let object: Vector(Byte) = coff_object(X86Object(sections=lowered.sections, symbols=lowered.symbols, relocations=lowered.relocations))?;
    catch(err) {
        print("FAIL: edge object");
        return 1;
    }
    print("PASS: x86_64 edge copies");
    print("OBJECT-BEGIN");
    i = 0;
    while (i < object.length()) {
        print(Int(object[i]));
        i++;
    }
    print("OBJECT-END");
    return 0;
}
