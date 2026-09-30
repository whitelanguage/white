// Test: WIR_OPTIMIZE
// File: tests/integration/tooling/test_wir_optimize.wl
// Focus: Dead computations, constant branches, SSA remapping and observable effects.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/verify.wl"
import * from "../../../src/compiler/wir/optimize.wl"

func check_cleanup() -> Bool {
    let program = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32 = wir_signed_int_type(ref program, 32);
    let function = wir_add_function(ref program, "cleanup", [], i32, false, WirLinkage.Exported, WirABI.White);
    let entry = wir_add_block(ref program, function, "entry", []);
    let exit = wir_add_block(ref program, function, "exit", [WirParam(name="answer", type_id=i32)]);
    let dead = wir_add_block(ref program, function, "dead", []);
    let location = no_wir_location();
    let one = wir_const_int(ref program, i32, UInt128(1U));
    let unused = wir_append(ref program, entry, WirOpcode.Add, i32, [one, one], [], location);
    wir_append(ref program, entry, WirOpcode.Multiply, i32, [unused, one], [], location);
    let answer = wir_append(ref program, entry, WirOpcode.Add, i32, [one, one], [], location);
    wir_append(ref program, entry, WirOpcode.Branch, program.void_type, [wir_const_bool(ref program, true)], [wir_edge(exit, [answer]), wir_edge(dead, [])], location);
    wir_return(ref program, exit, program.arena.blocks[wir_id_index(UInt32(exit))].parameters[0], location);
    wir_append(ref program, dead, WirOpcode.Trap, program.void_type, [], [], location);
    if (verify_wir(program).length() != 0) { return false; }
    let before: Int = program.arena.instructions.length();
    let baseline = optimize_wir(ref program, "-O0");
    if (baseline.instructions != 0 || program.arena.instructions.length() != before) { return false; }
    let stats = optimize_wir(ref program, "-Oz");
    if (stats.instructions != 4 || stats.blocks != 1 || stats.branches != 1 || stats.constants != 3) { return false; }
    if (verify_wir(program).length() != 0) { return false; }
    let again = optimize_wir(ref program, "-O2");
    return again.instructions == 0 && again.branches == 0 && verify_wir(program).length() == 0;
}

func check_effects() -> Bool {
    let program = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32 = wir_signed_int_type(ref program, 32);
    let pointer = wir_pointer_type(ref program, i32);
    let external = wir_add_function(ref program, "observable", [], i32, false, WirLinkage.External, WirABI.C);
    let function = wir_add_function(ref program, "effects", [WirParam(name="p", type_id=pointer), WirParam(name="divisor", type_id=i32)], i32, false, WirLinkage.Exported, WirABI.White);
    let entry = wir_add_block(ref program, function, "entry", []);
    let parameters = program.arena.functions[wir_id_index(UInt32(function))].parameters;
    let location = no_wir_location();
    let one = wir_const_int(ref program, i32, UInt128(1U));
    wir_load(ref program, entry, parameters[0], "unused_load", location);
    wir_atomic_load(ref program, entry, parameters[0], WirMemoryOrder.Acquire, "unused_atomic", location);
    wir_store(ref program, entry, one, parameters[0], location);
    wir_append(ref program, entry, WirOpcode.SignedDivide, i32, [one, parameters[1]], [], location);
    wir_append(ref program, entry, WirOpcode.NullCheck, program.void_type, [parameters[0]], [], location);
    wir_append(ref program, entry, WirOpcode.Retain, program.void_type, [parameters[0]], [], location);
    wir_append(ref program, entry, WirOpcode.Release, program.void_type, [parameters[0]], [], location);
    wir_call(ref program, entry, program.arena.functions[wir_id_index(UInt32(external))].address, [], "unused_call", location);
    let f64 = wir_float_type(ref program, 64);
    let nan = wir_const_float_bits(ref program, f64, 9221120237041090561UL);
    let negative_zero = wir_const_float_bits(ref program, f64, 9223372036854775808UL);
    wir_append(ref program, entry, WirOpcode.Add, f64, [nan, negative_zero], [], location);
    wir_append(ref program, entry, WirOpcode.Equal, program.bool_type, [nan, nan], [], location);
    wir_return(ref program, entry, one, location);
    if (verify_wir(program).length() != 0) { return false; }
    let stats = optimize_wir(ref program, "-O3");
    return stats.instructions == 0 && verify_wir(program).length() == 0;
}

func check_loop() -> Bool {
    let program = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32 = wir_signed_int_type(ref program, 32);
    let function = wir_add_function(ref program, "loop", [WirParam(name="condition", type_id=program.bool_type)], i32, false, WirLinkage.Exported, WirABI.White);
    let entry = wir_add_block(ref program, function, "entry", []);
    let loop = wir_add_block(ref program, function, "loop", [WirParam(name="count", type_id=i32)]);
    let exit = wir_add_block(ref program, function, "exit", [WirParam(name="answer", type_id=i32)]);
    let one = wir_const_int(ref program, i32, UInt128(1U));
    let location = no_wir_location();
    wir_append(ref program, entry, WirOpcode.Jump, program.void_type, [], [wir_edge(loop, [one])], location);
    let count = program.arena.blocks[wir_id_index(UInt32(loop))].parameters[0];
    let operands: Vector(WirValueID) = [count, one];
    wir_append(ref program, loop, WirOpcode.Subtract, i32, operands, [], location);
    let next = wir_append(ref program, loop, WirOpcode.Add, i32, operands, [], location);
    let condition = program.arena.functions[wir_id_index(UInt32(function))].parameters[0];
    wir_append(ref program, loop, WirOpcode.Branch, program.void_type, [condition], [wir_edge(loop, [next]), wir_edge(exit, [next])], location);
    wir_return(ref program, exit, program.arena.blocks[wir_id_index(UInt32(exit))].parameters[0], location);
    if (verify_wir(program).length() != 0) { return false; }
    let stats = optimize_wir(ref program, "-O1");
    return stats.instructions == 1 && stats.blocks == 0 && stats.parameters == 0 && verify_wir(program).length() == 0;
}

func check_stack_forwarding() -> Bool {
    let program = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32 = wir_signed_int_type(ref program, 32);
    let function = wir_add_function(ref program, "forward", [], i32, false, WirLinkage.Exported, WirABI.White);
    let entry = wir_add_block(ref program, function, "entry", []);
    let location = no_wir_location();
    let value = wir_const_int(ref program, i32, UInt128(42U));
    let slot = wir_stack_alloc(ref program, entry, i32, "value", location);
    wir_store(ref program, entry, value, slot, location);
    let loaded = wir_load(ref program, entry, slot, "loaded", location);
    wir_return(ref program, entry, loaded, location);
    if (verify_wir(program).length() != 0) { return false; }
    let stats = optimize_wir(ref program, "-O1");
    if (stats.loads != 1 || stats.stores != 1 || stats.slots != 1 || verify_wir(program).length() != 0) { return false; }
    if (program.arena.instructions.length() != 1 || program.arena.instructions[0].opcode != WirOpcode.Return) { return false; }
    return program.arena.instructions[0].operands[0] == value;
}

func check_escaping_slot() -> Bool {
    let program = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32 = wir_signed_int_type(ref program, 32);
    let pointer = wir_pointer_type(ref program, i32);
    let external = wir_add_function(ref program, "observe", [WirParam(name="value", type_id=pointer)], program.void_type, false, WirLinkage.External, WirABI.C);
    let function = wir_add_function(ref program, "escape", [], i32, false, WirLinkage.Exported, WirABI.White);
    let entry = wir_add_block(ref program, function, "entry", []);
    let location = no_wir_location();
    let value = wir_const_int(ref program, i32, UInt128(42U));
    let slot = wir_stack_alloc(ref program, entry, i32, "value", location);
    wir_store(ref program, entry, value, slot, location);
    wir_call(ref program, entry, program.arena.functions[wir_id_index(UInt32(external))].address, [slot], "", location);
    let loaded = wir_load(ref program, entry, slot, "loaded", location);
    wir_return(ref program, entry, loaded, location);
    if (verify_wir(program).length() != 0) { return false; }
    let stats = optimize_wir(ref program, "-Oz");
    if (stats.loads != 0 || stats.stores != 0 || stats.slots != 0 || verify_wir(program).length() != 0) { return false; }
    let load_found = false;
    let store_found = false;
    let i = 0;
    while (i < program.arena.instructions.length()) {
        if (program.arena.instructions[i].opcode == WirOpcode.Load) { load_found = true; }
        if (program.arena.instructions[i].opcode == WirOpcode.Store) { store_found = true; }
        i++;
    }
    return load_found && store_found;
}

func check_stack_boundaries() -> Bool {
    let program = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32 = wir_signed_int_type(ref program, 32);
    let location = no_wir_location();
    let one = wir_const_int(ref program, i32, UInt128(1U));
    let function = wir_add_function(ref program, "blocks", [], i32, false, WirLinkage.Exported, WirABI.White);
    let entry = wir_add_block(ref program, function, "entry", []);
    let exit = wir_add_block(ref program, function, "exit", []);
    let producer = wir_add_block(ref program, function, "producer", []);
    let slot = wir_stack_alloc(ref program, entry, i32, "slot", location);
    wir_store(ref program, entry, one, slot, location);
    wir_append(ref program, entry, WirOpcode.Jump, program.void_type, [], [wir_edge(producer, [])], location);
    // block table order differs from dominance order; the exit must see the final alias
    let loaded = wir_load(ref program, producer, slot, "cross_block", location);
    wir_store(ref program, producer, one, slot, location);
    let forwarded = wir_load(ref program, producer, slot, "forwarded", location);
    wir_append(ref program, producer, WirOpcode.Jump, program.void_type, [], [wir_edge(exit, [])], location);
    wir_return(ref program, exit, forwarded, location);

    let uninitialized = wir_add_function(ref program, "uninitialized", [], i32, false, WirLinkage.Exported, WirABI.White);
    let start = wir_add_block(ref program, uninitialized, "entry", []);
    let unknown = wir_stack_alloc(ref program, start, i32, "unknown", location);
    let before_store = wir_load(ref program, start, unknown, "before_store", location);
    wir_store(ref program, start, one, unknown, location);
    wir_return(ref program, start, before_store, location);

    let atomic = wir_add_function(ref program, "atomic", [], i32, false, WirLinkage.Exported, WirABI.White);
    let atomic_entry = wir_add_block(ref program, atomic, "entry", []);
    let atomic_slot = wir_stack_alloc(ref program, atomic_entry, i32, "atomic_slot", location);
    wir_store(ref program, atomic_entry, one, atomic_slot, location);
    wir_atomic_store(ref program, atomic_entry, one, atomic_slot, WirMemoryOrder.Release, location);
    let after_atomic = wir_load(ref program, atomic_entry, atomic_slot, "after_atomic", location);
    wir_return(ref program, atomic_entry, after_atomic, location);
    if (verify_wir(program).length() != 0) { return false; }
    let stats = optimize_wir(ref program, "-Oz");
    if (stats.loads != 1 || stats.slots != 0 || stats.stores != 0 || verify_wir(program).length() != 0) { return false; }
    let remaining_loads = 0;
    let i = 0;
    while (i < program.arena.instructions.length()) {
        if (program.arena.instructions[i].opcode == WirOpcode.Load) { remaining_loads++; }
        i++;
    }
    return remaining_loads == 3;
}

func check_block_parameters() -> Bool {
    let program = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32 = wir_signed_int_type(ref program, 32);
    let function = wir_add_function(ref program, "parameters", [WirParam(name="condition", type_id=program.bool_type)], i32, false, WirLinkage.Exported, WirABI.White);
    let entry = wir_add_block(ref program, function, "entry", []);
    let left = wir_add_block(ref program, function, "left", []);
    let right = wir_add_block(ref program, function, "right", []);
    let join = wir_add_block(ref program, function, "join", [WirParam(name="same", type_id=i32), WirParam(name="different", type_id=i32)]);
    let location = no_wir_location();
    let one = wir_const_int(ref program, i32, UInt128(1U));
    let two = wir_const_int(ref program, i32, UInt128(2U));
    let condition = program.arena.functions[wir_id_index(UInt32(function))].parameters[0];
    wir_append(ref program, entry, WirOpcode.Branch, program.void_type, [condition], [wir_edge(left, []), wir_edge(right, [])], location);
    wir_append(ref program, left, WirOpcode.Jump, program.void_type, [], [wir_edge(join, [one, one])], location);
    wir_append(ref program, right, WirOpcode.Jump, program.void_type, [], [wir_edge(join, [one, two])], location);
    wir_return(ref program, join, program.arena.blocks[wir_id_index(UInt32(join))].parameters[0], location);
    if (verify_wir(program).length() != 0) { return false; }
    let stats = optimize_wir(ref program, "-O2");
    if (stats.parameters != 1 || verify_wir(program).length() != 0) { return false; }
    let block = program.arena.blocks[wir_id_index(UInt32(join))];
    let returned = program.arena.instructions[program.arena.instructions.length() - 1].operands[0];
    if (block.parameters.length() != 1 || program.arena.values[wir_id_index(UInt32(returned))].integer != UInt128(1U)) { return false; }
    let i = 0;
    while (i < program.arena.instructions.length()) {
        let instruction = program.arena.instructions[i];
        let edge = 0;
        while (edge < instruction.edges.length()) {
            if (instruction.edges[edge].target == join && instruction.edges[edge].arguments.length() != 1) { return false; }
            edge++;
        }
        i++;
    }
    return true;
}

func check_constant(op: WirOpcode, bits: Int, signed: Bool, lhs: UInt128, rhs: UInt128, expected: UInt128, comparison: Bool) -> Bool {
    let program = new_wir_module("x86_64-pc-windows-msvc", 64);
    let type = wir_unsigned_int_type(ref program, bits);
    if (signed) { type = wir_signed_int_type(ref program, bits); }
    let result_type = type;
    if (comparison) { result_type = program.bool_type; }
    let function = wir_add_function(ref program, "constant", [], result_type, false, WirLinkage.Exported, WirABI.White);
    let entry = wir_add_block(ref program, function, "entry", []);
    let a = wir_const_int(ref program, type, lhs);
    let b = wir_const_int(ref program, type, rhs);
    let result = wir_append(ref program, entry, op, result_type, [a, b], [], no_wir_location());
    wir_return(ref program, entry, result, no_wir_location());
    if (verify_wir(program).length() != 0) { return false; }
    let stats = optimize_wir(ref program, "-O2");
    if (stats.constants != 1 || verify_wir(program).length() != 0) { return false; }
    let returned = program.arena.instructions[0].operands[0];
    return program.arena.values[wir_id_index(UInt32(returned))].integer == expected;
}

func main() -> Int {
    if (!check_cleanup()) { print("FAIL: WIR cleanup or value remapping"); return 1; }
    if (!check_effects()) { print("FAIL: WIR optimization removed observable effects"); return 1; }
    if (!check_loop()) { print("FAIL: WIR optimization changed a loop edge"); return 1; }
    if (!check_stack_forwarding()) { print("FAIL: WIR stack slot forwarding"); return 1; }
    if (!check_escaping_slot()) { print("FAIL: WIR optimizer promoted an escaping stack slot"); return 1; }
    if (!check_stack_boundaries()) { print("FAIL: WIR forwarding crossed a memory or block boundary"); return 1; }
    if (!check_block_parameters()) { print("FAIL: WIR block parameter elimination"); return 1; }
    if (!check_constant(WirOpcode.Add, 8, false, UInt128(255U), UInt128(1U), UInt128(0U), false) ||
        !check_constant(WirOpcode.Subtract, 32, true, UInt128(0U), UInt128(1U), UInt128(4294967295U), false) ||
        !check_constant(WirOpcode.Multiply, 64, false, UInt128(18446744073709551615UL), UInt128(2U), UInt128(18446744073709551614UL), false) ||
        !check_constant(WirOpcode.SignedLess, 128, true, UInt128(1U) << 127, UInt128(1U), UInt128(1U), true) ||
        !check_constant(WirOpcode.UnsignedLess, 128, false, UInt128(1U) << 127, UInt128(1U), UInt128(0U), true)) {
        print("FAIL: WIR constant folding changed integer width or signedness");
        return 1;
    }
    print("PASS: WIR optimization");
    return 0;
}
