// Test: AARCH64_EDGE_MOVES
// File: tests/machine/aarch64/test_edge_moves.wl
// Focus: Forward register contracts, parallel swaps and loop homes for scalar and aggregate values.

import "file"
import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import verify_wir from "../../../src/compiler/wir/verify.wl"
import * from "../../../src/compiler/machine/aarch64/model.wl"
import * from "../../../src/compiler/machine/aarch64/encoder.wl"
import a64_float_move from "../../../src/compiler/machine/aarch64/fp.wl"
import a64_load_integer_at, a64_load_float_at from "../../../src/compiler/machine/aarch64/memory.wl"
import * from "../../../src/compiler/machine/aarch64/allocator.wl"
import * from "../../../src/compiler/machine/aarch64/lowering.wl"
import a64_elf_object from "../../../src/compiler/machine/aarch64/elf.wl"
import x86_lower_module from "../../../src/compiler/machine/x86_64/lowering.wl"
import X86Object from "../../../src/compiler/machine/x86_64/model.wl"
import elf_object from "../../../src/compiler/machine/x86_64/elf.wl"


func copy_cycles() -> Bool {
    let output = a64_new_code_buffer();
    let expected = a64_new_code_buffer();
    let copies: Vector(A64EdgeCopy) = [
        A64EdgeCopy(destination=A64Register.X9, source=A64Register.X10, offset=0, width=64, floating=false),
        A64EdgeCopy(destination=A64Register.X10, source=A64Register.X11, offset=8, width=64, floating=false),
        A64EdgeCopy(destination=A64Register.X11, source=A64Register.X9, offset=16, width=64, floating=false)
    ];
    if (!a64_repair_edge(copies, ref output)) { return false; }
    a64_mov_register(ref expected, A64Register.X10, A64Register.X11, true);
    a64_mov_register(ref expected, A64Register.X11, A64Register.X9, true);
    a64_load_integer_at(ref expected, A64Register.X9, A64Register.SP, 0, 64);
    copies = [
        A64EdgeCopy(destination=A64Register.V16, source=A64Register.V17, offset=24, width=32, floating=true),
        A64EdgeCopy(destination=A64Register.V17, source=A64Register.V16, offset=28, width=32, floating=true)
    ];
    if (!a64_repair_edge(copies, ref output)) { return false; }
    a64_float_move(ref expected, A64Register.V17, A64Register.V16, false);
    a64_load_float_at(ref expected, A64Register.V16, A64Register.SP, 24, false);
    if (output.bytes.length() != expected.bytes.length()) { return false; }
    let i = 0;
    while (i < output.bytes.length()) {
        if (output.bytes[i] != expected.bytes[i]) { return false; }
        i++;
    }
    return true;
}

func stack_accesses(bytes: Vector(Byte)) -> Int {
    let count = 0;
    let i = 0;
    while (i + 3 < bytes.length()) {
        let word = UInt32(bytes[i]) | (UInt32(bytes[i + 1]) << 8U) |
            (UInt32(bytes[i + 2]) << 16U) | (UInt32(bytes[i + 3]) << 24U);
        if ((word & 0x3B000000U) == 0x39000000U && ((word >> 5U) & 31U) == 31U) { count++; }
        i += 4;
    }
    return count;
}

func rotate(ref program: WirModule, name: String, type: WirTypeID, a: WirValueID, b: WirValueID, c: WirValueID) -> WirFuncID {
    let int = wir_signed_int_type(ref program, 32);
    let id = wir_add_function(ref program, name, [wir_param("count", int)], type, false, WirLinkage.Exported, WirABI.C);
    let entry = wir_add_block(ref program, id, "entry", []);
    let loop = wir_add_block(ref program, id, "loop", [wir_param("a", type), wir_param("b", type), wir_param("c", type), wir_param("n", int)]);
    let exit = wir_add_block(ref program, id, "exit", []);
    let params = program.arena.blocks[wir_id_index(UInt32(loop))].parameters;
    let count = program.arena.functions[wir_id_index(UInt32(id))].parameters[0];
    let zero = wir_const_int(ref program, int, UInt128(0U));
    let one = wir_const_int(ref program, int, UInt128(1U));
    if (a64_aggregate_type(ref program, type)) {
        let ca = program.arena.constants[wir_id_index(program.arena.values[wir_id_index(UInt32(a))].owner)];
        let cb = program.arena.constants[wir_id_index(program.arena.values[wir_id_index(UInt32(b))].owner)];
        let cc = program.arena.constants[wir_id_index(program.arena.values[wir_id_index(UInt32(c))].owner)];
        a = wir_struct_value(ref program, entry, type, ca.elements, "a", no_wir_location());
        b = wir_struct_value(ref program, entry, type, cb.elements, "b", no_wir_location());
        c = wir_struct_value(ref program, entry, type, cc.elements, "c", no_wir_location());
    }
    wir_append(ref program, entry, WirOpcode.Jump, program.void_type, [], [wir_edge(loop, [a, b, c, zero])], no_wir_location());
    let next = wir_binary(ref program, loop, WirOpcode.Add, int, params[3], one, "next", no_wir_location());
    let more = wir_binary(ref program, loop, WirOpcode.SignedLess, program.bool_type, params[3], count, "more", no_wir_location());
    wir_append(ref program, loop, WirOpcode.Branch, program.void_type, [more],
        [wir_edge(loop, [params[1], params[2], params[0], next]), wir_edge(exit, [])], no_wir_location());
    wir_return(ref program, exit, params[0], no_wir_location());

    let uses = a64_collect_uses(ref program, program.arena.functions[wir_id_index(UInt32(id))].blocks);
    a64_mark_edge_registers(ref program, program.arena.functions[wir_id_index(UInt32(id))].blocks, ref uses);
    if (a64_incoming_register(ref uses, params[0]) != A64Register.None) { return NO_WIR_FUNC; }
    return id;
}

func join(ref program: WirModule) -> WirFuncID {
    let int = wir_signed_int_type(ref program, 32);
    let id = wir_add_function(ref program, "edge_join", [wir_param("choose", program.bool_type),
        wir_param("a", int), wir_param("b", int), wir_param("c", int)], int, false, WirLinkage.Exported, WirABI.C);
    let entry = wir_add_block(ref program, id, "entry", []);
    let target = wir_add_block(ref program, id, "join", [wir_param("a", int), wir_param("b", int), wir_param("c", int)]);
    let args = program.arena.functions[wir_id_index(UInt32(id))].parameters;
    let params = program.arena.blocks[wir_id_index(UInt32(target))].parameters;
    wir_append(ref program, entry, WirOpcode.Branch, program.void_type, [args[0]],
        [wir_edge(target, [args[2], args[3], args[1]]), wir_edge(target, [args[2], args[2], args[1]])], no_wir_location());
    let hundreds = wir_const_int(ref program, int, UInt128(100U));
    let tens = wir_const_int(ref program, int, UInt128(10U));
    let a = wir_binary(ref program, target, WirOpcode.Multiply, int, params[0], hundreds, "hundreds", no_wir_location());
    let b = wir_binary(ref program, target, WirOpcode.Multiply, int, params[1], tens, "tens", no_wir_location());
    let sum = wir_binary(ref program, target, WirOpcode.Add, int, a, b, "sum", no_wir_location());
    sum = wir_binary(ref program, target, WirOpcode.Add, int, sum, params[2], "result", no_wir_location());
    wir_return(ref program, target, sum, no_wir_location());

    let uses = a64_collect_uses(ref program, program.arena.functions[wir_id_index(UInt32(id))].blocks);
    a64_mark_edge_registers(ref program, program.arena.functions[wir_id_index(UInt32(id))].blocks, ref uses);
    if (a64_incoming_register(ref uses, params[0]) != A64Register.X9 ||
        a64_incoming_register(ref uses, params[1]) != A64Register.X10 ||
        a64_incoming_register(ref uses, params[2]) != A64Register.X11) { return NO_WIR_FUNC; }
    return id;
}

func float_join(ref program: WirModule) -> WirFuncID {
    let float = wir_float_type(ref program, 64);
    let id = wir_add_function(ref program, "edge_float", [wir_param("a", float), wir_param("b", float)], float, false, WirLinkage.Exported, WirABI.C);
    let entry = wir_add_block(ref program, id, "entry", []);
    let target = wir_add_block(ref program, id, "join", [wir_param("a", float), wir_param("b", float)]);
    let args = program.arena.functions[wir_id_index(UInt32(id))].parameters;
    let params = program.arena.blocks[wir_id_index(UInt32(target))].parameters;
    // make both sources resident before transferring them in the reverse order.
    let one = wir_const_float(ref program, float, 1.0);
    let a = wir_binary(ref program, entry, WirOpcode.Add, float, args[0], one, "a", no_wir_location());
    let b = wir_binary(ref program, entry, WirOpcode.Add, float, args[1], one, "b", no_wir_location());
    wir_append(ref program, entry, WirOpcode.Jump, program.void_type, [], [wir_edge(target, [b, a])], no_wir_location());
    let ten = wir_const_float(ref program, float, 10.0);
    let value = wir_binary(ref program, target, WirOpcode.Multiply, float, params[0], ten, "scaled", no_wir_location());
    value = wir_binary(ref program, target, WirOpcode.Add, float, value, params[1], "result", no_wir_location());
    wir_return(ref program, target, value, no_wir_location());
    return id;
}

func main() -> Int {
    if (!copy_cycles()) {
        print("FAIL: AArch64 register cycle repair");
        return 1;
    }
    let program = new_wir_module("aarch64-unknown-linux-gnu", 64);
    let int = wir_signed_int_type(ref program, 32);
    let long = wir_signed_int_type(ref program, 64);
    let wide = wir_unsigned_int_type(ref program, 128);
    let float = wir_float_type(ref program, 64);
    let record = wir_struct_type(ref program, [long, long]);
    let one = wir_const_int(ref program, long, UInt128(1U));
    let two = wir_const_int(ref program, long, UInt128(2U));
    let three = wir_const_int(ref program, long, UInt128(3U));
    let functions: Vector(WirFuncID) = [join(ref program), float_join(ref program)];
    functions.append(rotate(ref program, "edge_int_loop", int, wir_const_int(ref program, int, UInt128(1U)),
        wir_const_int(ref program, int, UInt128(2U)), wir_const_int(ref program, int, UInt128(3U))));
    let high = UInt128(1U) << UInt128(100U);
    functions.append(rotate(ref program, "edge_wide_loop", wide, wir_const_int(ref program, wide, high + UInt128(1U)),
        wir_const_int(ref program, wide, high + UInt128(2U)), wir_const_int(ref program, wide, high + UInt128(3U))));
    functions.append(rotate(ref program, "edge_float_loop", float, wir_const_float(ref program, float, 1.5),
        wir_const_float(ref program, float, 2.5), wir_const_float(ref program, float, 3.5)));
    functions.append(rotate(ref program, "edge_record_loop", record, wir_const_aggregate(ref program, record, [one, two]),
        wir_const_aggregate(ref program, record, [two, three]), wir_const_aggregate(ref program, record, [three, one])));

    let floating = a64_lower_function(ref program, functions[1]);
    // two ABI saves, two initial loads and two edge snapshots suffice.
    // Entry parameters must not be reloaded after their register transfer.
    if (floating.errors.length() != 0 || stack_accesses(floating.bytes) > 6) {
        print("FAIL: forward float edge adds redundant homes, accesses ", stack_accesses(floating.bytes));
        return 1;
    }

    let errors = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: edge WIR: ", errors[0]);
        return 1;
    }
    let i = 0;
    while (i < functions.length()) {
        if (functions[i] == NO_WIR_FUNC) {
            print("FAIL: AArch64 edge register eligibility");
            return 1;
        }
        i++;
    }
    let lowered = a64_lower_module(ref program);
    if (lowered.errors.length() != 0) {
        print("FAIL: edge lowering: ", lowered.errors[0]);
        return 1;
    }
    let bytes = a64_elf_object(A64Object(sections=lowered.sections, symbols=lowered.symbols, relocations=lowered.relocations))?;
    catch(err) { return 1; }
    let output = file.create("a64_edge_moves.o")?;
    catch(err) { return 1; }
    output.write_bytes(bytes)?;
    catch(err) { return 1; }
    output.close();

    // use the same WIR and C host on x86-64, target parity should cover
    // actual edge values rather than just matching opcode switches.
    program.target = "x86_64-unknown-linux-gnu";
    let x86 = x86_lower_module(ref program);
    if (x86.errors.length() != 0) {
        print("FAIL: x86 edge lowering: ", x86.errors[0]);
        return 1;
    }
    bytes = elf_object(X86Object(sections=x86.sections, symbols=x86.symbols, relocations=x86.relocations))?;
    catch(err) { return 1; }
    output = file.create("x86_edge_moves.o")?;
    catch(err) { return 1; }
    output.write_bytes(bytes)?;
    catch(err) { return 1; }
    output.close();

    print("PASS: AArch64 edge register contracts and parallel copies");
    return 0;
}
