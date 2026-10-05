// Test: WIR_LOCAL_CSE
// File: tests/integration/tooling/test_wir_cse.wl
// Focus: Bounded integer expression reuse, SSA aliases and effect boundaries.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/verify.wl"
import * from "../../../src/compiler/wir/optimize.wl"

func check_pair(op: WirOpcode, bits: Int, swapped: Bool, level: String, expected: Int) -> Bool {
    let program = new_wir_module("x86_64-pc-windows-msvc", 64);
    let type = wir_signed_int_type(ref program, bits);
    let function = wir_add_function(ref program, "pair", [WirParam(name="a", type_id=type), WirParam(name="b", type_id=type)], type, false, WirLinkage.Exported, WirABI.White);
    let entry = wir_add_block(ref program, function, "entry", []);
    let args = program.arena.functions[wir_id_index(UInt32(function))].parameters;
    let pos = no_wir_location();
    let a = wir_binary(ref program, entry, op, type, args[0], args[1], "a", pos);
    let left = args[0];
    let right = args[1];
    if (swapped) {
        left = args[1];
        right = args[0];
    }
    let b = wir_binary(ref program, entry, op, type, left, right, "b", pos);
    let result = wir_binary(ref program, entry, WirOpcode.Add, type, a, b, "result", pos);
    wir_return(ref program, entry, result, pos);
    if (verify_wir(program).length() != 0) {
        return false;
    }
    let stats = optimize_wir(ref program, level);
    if (stats.expressions != expected || verify_wir(program).length() != 0) {
        return false;
    }
    let ptr sum: WirInstruction = ref program.arena.instructions[program.arena.instructions.length() - 2];
    return (sum.operands[0] == sum.operands[1]) == (expected == 1);
}

func check_alias_chain() -> Bool {
    let program = new_wir_module("x86_64-pc-windows-msvc", 64);
    let type = wir_signed_int_type(ref program, 32);
    let function = wir_add_function(ref program, "chain", [WirParam(name="a", type_id=type), WirParam(name="b", type_id=type)], type, false, WirLinkage.Exported, WirABI.White);
    let entry = wir_add_block(ref program, function, "entry", []);
    let args = program.arena.functions[wir_id_index(UInt32(function))].parameters;
    let pos = no_wir_location();
    let a = wir_binary(ref program, entry, WirOpcode.Multiply, type, args[0], args[1], "a", pos);
    let b = wir_binary(ref program, entry, WirOpcode.Multiply, type, args[1], args[0], "b", pos);
    let c = wir_binary(ref program, entry, WirOpcode.BitXor, type, a, args[0], "c", pos);
    let d = wir_binary(ref program, entry, WirOpcode.BitXor, type, b, args[0], "d", pos);
    let sum = wir_binary(ref program, entry, WirOpcode.Add, type, c, d, "sum", pos);
    wir_return(ref program, entry, sum, pos);
    let stats = optimize_wir(ref program, "-O2");
    if (stats.expressions != 2 || verify_wir(program).length() != 0) {
        return false;
    }
    return optimize_wir(ref program, "-O2").instructions == 0;
}

func check_boundaries(gap: Int, call: Bool, separate_block: Bool, level: String, expected: Int) -> Bool {
    let program = new_wir_module("x86_64-pc-windows-msvc", 64);
    let type = wir_signed_int_type(ref program, 32);
    let pointer = wir_pointer_type(ref program, type);
    let external = wir_add_function(ref program, "external", [], program.void_type, false, WirLinkage.External, WirABI.C);
    let function = wir_add_function(ref program, "bounded", [WirParam(name="a", type_id=type), WirParam(name="b", type_id=type), WirParam(name="p", type_id=pointer)], type, false, WirLinkage.Exported, WirABI.White);
    let entry = wir_add_block(ref program, function, "entry", []);
    let args = program.arena.functions[wir_id_index(UInt32(function))].parameters;
    let pos = no_wir_location();
    let first = wir_binary(ref program, entry, WirOpcode.Add, type, args[0], args[1], "first", pos);
    wir_store(ref program, entry, first, args[2], pos);
    let i = 0;
    while (i < gap) {
        wir_store(ref program, entry, args[0], args[2], pos);
        i++;
    }
    if (call) {
        wir_call(ref program, entry, program.arena.functions[wir_id_index(UInt32(external))].address, [], "", pos);
    }
    let block = entry;
    if (separate_block) {
        block = wir_add_block(ref program, function, "next", []);
        wir_append(ref program, entry, WirOpcode.Jump, program.void_type, [], [wir_edge(block, [])], pos);
    }
    let last = wir_binary(ref program, block, WirOpcode.Add, type, args[0], args[1], "last", pos);
    wir_return(ref program, block, last, pos);
    if (verify_wir(program).length() != 0) {
        return false;
    }
    let stats = optimize_wir(ref program, level);
    return stats.expressions == expected && verify_wir(program).length() == 0;
}

func check_effects() -> Bool {
    let program = new_wir_module("x86_64-pc-windows-msvc", 64);
    let integer = wir_signed_int_type(ref program, 32);
    let float = wir_float_type(ref program, 64);
    let pointer = wir_pointer_type(ref program, integer);
    let function = wir_add_function(ref program, "effects", [WirParam(name="a", type_id=integer), WirParam(name="b", type_id=integer), WirParam(name="p", type_id=pointer), WirParam(name="f", type_id=float)], integer, false, WirLinkage.Exported, WirABI.White);
    let entry = wir_add_block(ref program, function, "entry", []);
    let args = program.arena.functions[wir_id_index(UInt32(function))].parameters;
    let pos = no_wir_location();
    let i = 0;
    while (i < 2) {
        wir_load(ref program, entry, args[2], "load", pos);
        wir_atomic_load(ref program, entry, args[2], WirMemoryOrder.Acquire, "atomic", pos);
        wir_binary(ref program, entry, WirOpcode.SignedDivide, integer, args[0], args[1], "div", pos);
        wir_binary(ref program, entry, WirOpcode.Add, float, args[3], args[3], "float", pos);
        wir_binary(ref program, entry, WirOpcode.Equal, program.bool_type, args[3], args[3], "eq", pos);
        i++;
    }
    wir_return(ref program, entry, args[0], pos);
    let stats = optimize_wir(ref program, "-O3");
    return stats.expressions == 0 && stats.instructions == 0 && verify_wir(program).length() == 0;
}

func check_keys() -> Bool {
    let program = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i64 = wir_signed_int_type(ref program, 64);
    let i32 = wir_signed_int_type(ref program, 32);
    let i16 = wir_signed_int_type(ref program, 16);
    let p32 = wir_pointer_type(ref program, i32);
    let p16 = wir_pointer_type(ref program, i16);
    let function = wir_add_function(ref program, "keys", [WirParam(name="a", type_id=i64), WirParam(name="p", type_id=p32), WirParam(name="q", type_id=p16)], i64, false, WirLinkage.Exported, WirABI.White);
    let entry = wir_add_block(ref program, function, "entry", []);
    let args = program.arena.functions[wir_id_index(UInt32(function))].parameters;
    let pos = no_wir_location();
    let a = wir_append(ref program, entry, WirOpcode.Truncate, i32, [args[0]], [], pos);
    let b = wir_append(ref program, entry, WirOpcode.Truncate, i16, [args[0]], [], pos);
    let c = wir_append(ref program, entry, WirOpcode.Truncate, i32, [args[0]], [], pos);
    wir_store(ref program, entry, a, args[1], pos);
    wir_store(ref program, entry, b, args[2], pos);
    wir_store(ref program, entry, c, args[1], pos);
    let extended = wir_append(ref program, entry, WirOpcode.SignExtend, i64, [a], [], pos);
    let negated = wir_append(ref program, entry, WirOpcode.Negate, i64, [extended], [], pos);
    let inverted = wir_append(ref program, entry, WirOpcode.Not, i64, [extended], [], pos);
    let result = wir_binary(ref program, entry, WirOpcode.Add, i64, negated, inverted, "result", pos);
    wir_return(ref program, entry, result, pos);
    if (verify_wir(program).length() != 0) {
        return false;
    }
    let stats = optimize_wir(ref program, "-O2");
    return stats.expressions == 1 && verify_wir(program).length() == 0;
}

func check_collisions() -> Bool {
    let program = new_wir_module("x86_64-pc-windows-msvc", 64);
    let type = wir_signed_int_type(ref program, 32);
    let pointer = wir_pointer_type(ref program, type);
    let function = wir_add_function(ref program, "collisions", [WirParam(name="a", type_id=type), WirParam(name="p", type_id=pointer)], type, false, WirLinkage.Exported, WirABI.White);
    let entry = wir_add_block(ref program, function, "entry", []);
    let args = program.arena.functions[wir_id_index(UInt32(function))].parameters;
    let pos = no_wir_location();
    // more distinct keys than buckets. Every store must still use its own sum,
    // even when the cache replaces an earlier expression with a colliding key.
    let i = 1;
    while (i <= 512) {
        let constant = wir_const_int(ref program, type, UInt128(i));
        let sum = wir_binary(ref program, entry, WirOpcode.Add, type, args[0], constant, "sum", pos);
        wir_store(ref program, entry, sum, args[1], pos);
        i++;
    }
    wir_return(ref program, entry, args[0], pos);
    let stats = optimize_wir(ref program, "-O2");
    return stats.expressions == 0 && stats.instructions == 0 && verify_wir(program).length() == 0;
}

func check_literals(bits: Int) -> Bool {
    let program = new_wir_module("x86_64-pc-windows-msvc", 64);
    let type = wir_unsigned_int_type(ref program, bits);
    let function = wir_add_function(ref program, "literals", [WirParam(name="a", type_id=type)], type, false, WirLinkage.Exported, WirABI.White);
    let entry = wir_add_block(ref program, function, "entry", []);
    let arg = program.arena.functions[wir_id_index(UInt32(function))].parameters[0];
    let pos = no_wir_location();
    let literal = UInt128(19U);
    if (bits == 128) {
        literal = (UInt128(1U) << 100) | literal;
    }
    let x = wir_const_int(ref program, type, literal);
    let y = wir_const_int(ref program, type, literal);
    let first = wir_binary(ref program, entry, WirOpcode.BitAnd, type, arg, x, "first", pos);
    let second = wir_binary(ref program, entry, WirOpcode.BitAnd, type, y, arg, "second", pos);
    let result = wir_binary(ref program, entry, WirOpcode.Add, type, first, second, "result", pos);
    wir_return(ref program, entry, result, pos);
    if (verify_wir(program).length() != 0) {
        return false;
    }
    let stats = optimize_wir(ref program, "-O1");
    return stats.expressions == 1 && verify_wir(program).length() == 0;
}

func check_private_reads() -> Bool {
    let program = new_wir_module("x86_64-pc-windows-msvc", 64);
    let type = wir_signed_int_type(ref program, 32);
    let function = wir_add_function(ref program, "reads", [WirParam(name="a", type_id=type)], type, false, WirLinkage.Exported, WirABI.White);
    let entry = wir_add_block(ref program, function, "entry", []);
    let next = wir_add_block(ref program, function, "next", []);
    let arg = program.arena.functions[wir_id_index(UInt32(function))].parameters[0];
    let pos = no_wir_location();
    let slot = wir_stack_alloc(ref program, entry, type, "slot", pos);
    wir_store(ref program, entry, arg, slot, pos);
    wir_append(ref program, entry, WirOpcode.Jump, program.void_type, [], [wir_edge(next, [])], pos);
    let a = wir_load(ref program, next, slot, "first", pos);
    let b = wir_load(ref program, next, slot, "second", pos);
    let sum = wir_binary(ref program, next, WirOpcode.Add, type, a, b, "sum", pos);
    wir_store(ref program, next, sum, slot, pos);
    let c = wir_load(ref program, next, slot, "after_store", pos);
    let result = wir_binary(ref program, next, WirOpcode.Add, type, sum, c, "result", pos);
    wir_return(ref program, next, result, pos);
    if (verify_wir(program).length() != 0) {
        return false;
    }
    let stats = optimize_wir(ref program, "-O2");
    if (stats.loads != 2 || stats.stores != 0 || stats.slots != 0 || verify_wir(program).length() != 0) {
        return false;
    }
    let loads = 0;
    let i = 0;
    while (i < program.arena.instructions.length()) {
        if (program.arena.instructions[i].opcode == WirOpcode.Load) {
            loads++;
        }
        i++;
    }
    return loads == 1;
}

func main() -> Int {
    let levels = ["-O0", "-O1", "-O2", "-O3", "-Os", "-Oz"];
    let widths = [8, 16, 32, 64, 128];
    let i = 0;
    while (i < levels.length()) {
        let expected = 1;
        if (i == 0) {
            expected = 0;
        }
        let j = 0;
        while (j < widths.length()) {
            if (!check_pair(WirOpcode.Add, widths[j], true, levels[i], expected) ||
                !check_pair(WirOpcode.Subtract, widths[j], false, levels[i], expected) ||
                !check_pair(WirOpcode.Subtract, widths[j], true, levels[i], 0)) {
                print("FAIL: WIR expression reuse changed operand order or integer width");
                return 1;
            }
            j++;
        }
        i++;
    }
    if (!check_alias_chain()) {
        print("FAIL: WIR expression alias chain");
        return 1;
    }
    if (!check_effects()) {
        print("FAIL: WIR expression reuse removed observable effects");
        return 1;
    }
    if (!check_keys()) {
        print("FAIL: WIR expression type or opcode keys");
        return 1;
    }
    if (!check_collisions()) {
        print("FAIL: WIR expression hash collision");
        return 1;
    }
    if (!check_literals(32) || !check_literals(128)) {
        print("FAIL: WIR expression literal keys");
        return 1;
    }
    if (!check_private_reads()) {
        print("FAIL: WIR private stack read reuse");
        return 1;
    }
    if (!check_boundaries(0, false, false, "-O1", 1) ||
        !check_boundaries(8, false, false, "-O1", 0) ||
        !check_boundaries(8, false, false, "-O2", 1) ||
        !check_boundaries(32, false, false, "-O2", 0) ||
        !check_boundaries(0, true, false, "-O2", 0) ||
        !check_boundaries(0, false, true, "-O2", 0)) {
        print("FAIL: WIR expression reuse crossed its work or lifetime boundary");
        return 1;
    }
    print("PASS: WIR local expression reuse");
    return 0;
}
