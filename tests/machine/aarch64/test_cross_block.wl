// Test: AARCH64_CROSS_BLOCK
// File: tests/machine/aarch64/test_cross_block.wl
// Focus: Keep scalar and wide registers over straight edges, home values for joins and reordered blocks.

import "file"
import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import verify_wir from "../../../src/compiler/wir/verify.wl"
import * from "../../../src/compiler/machine/aarch64/model.wl"
import * from "../../../src/compiler/machine/aarch64/allocator.wl"
import * from "../../../src/compiler/machine/aarch64/lowering.wl"
import a64_elf_object from "../../../src/compiler/machine/aarch64/elf.wl"


func jump(ref program: WirModule, block: WirBlockID, target: WirBlockID) -> Void {
    wir_append(ref program, block, WirOpcode.Jump, program.void_type, [], [wir_edge(target, [])], no_wir_location());
}

func chain(ref program: WirModule, name: String, type: WirTypeID, extra: WirValueID) -> WirFuncID {
    let id: WirFuncID = wir_add_function(ref program, name, [wir_param("value", type)], type, false, WirLinkage.Exported, WirABI.C);
    let entry: WirBlockID = wir_add_block(ref program, id, "entry", []);
    let next: WirBlockID = wir_add_block(ref program, id, "next", []);
    let end: WirBlockID = wir_add_block(ref program, id, "end", []);
    let arg: WirValueID = program.arena.functions[wir_id_index(UInt32(id))].parameters[0];
    let value: WirValueID = wir_binary(ref program, entry, WirOpcode.Add, type, arg, extra, "sum", no_wir_location());

    jump(ref program, entry, next);
    jump(ref program, next, end);
    wir_return(ref program, end, value, no_wir_location());
    return id;
}

func stack_accesses(bytes: Vector(Byte)) -> Int {
    let count: Int = 0;
    let i: Int = 0;

    while (i + 3 < bytes.length()) {
        let word: UInt32 = UInt32(bytes[i]) | (UInt32(bytes[i + 1]) << 8U) |
                           (UInt32(bytes[i + 2]) << 16U) | (UInt32(bytes[i + 3]) << 24U);
        // unsigned-offset LDR/STR with SP as its base, exclude paired frame saves.
        if ((word & 0x3B000000U) == 0x39000000U && ((word >> 5U) & 31U) == 31U) {
            count++;
        }
        i += 4;
    }

    return count;
}

func main() -> Int {
    let program: WirModule = new_wir_module("aarch64-unknown-linux-gnu", 64);
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let f64: WirTypeID = wir_float_type(ref program, 64);
    let u128: WirTypeID = wir_unsigned_int_type(ref program, 128);
    let one: WirValueID = wir_const_int(ref program, i32, UInt128(1U));
    let scalar: WirFuncID = chain(ref program, "scalar_chain", i32, one);
    let floating: WirFuncID = chain(ref program, "float_chain", f64, wir_const_float(ref program, f64, 1.5));
    let wide: WirFuncID = chain(ref program, "wide_chain", u128, wir_const_int(ref program, u128, UInt128(1U)));
    let chains: Vector(WirFuncID) = [scalar, floating, wide];
    let i: Int = 0;

    while (i < chains.length()) {
        let function: WirFunction = program.arena.functions[wir_id_index(UInt32(chains[i]))];
        let preds: Dict(UInt32, Int) = a64_predecessor_counts(ref program, function.blocks);
        if (!a64_carry_to_next(ref program, function.blocks, preds, 0) ||
            !a64_carry_to_next(ref program, function.blocks, preds, 1) ||
            a64_carry_to_next(ref program, function.blocks, preds, 2)) {
            print("FAIL: straight AArch64 edges lost their register contract");
            return 1;
        }

        let lowered: A64LoweringResult = a64_lower_function(ref program, chains[i]);
        // incoming ABI registers still get homes and are loaded into the work bank.
        let expected: Int = 2;
        if (i == 2) { expected = 4; }
        if (lowered.errors.length() != 0 || stack_accesses(lowered.bytes) != expected) {
            print("FAIL: straight AArch64 edge still stores and reloads its result, case ", i, ", accesses ", stack_accesses(lowered.bytes));
            if (lowered.errors.length() != 0) { print(lowered.errors[0]); }
            return 1;
        }
        i++;
    }

    // definition dominates use, although its bytes are emitted later.
    let reordered: WirFuncID = wir_add_function(ref program, "reordered", [wir_param("value", i32)], i32, false, WirLinkage.Exported, WirABI.C);
    let entry: WirBlockID = wir_add_block(ref program, reordered, "entry", []);
    let use: WirBlockID = wir_add_block(ref program, reordered, "use", []);
    let definition: WirBlockID = wir_add_block(ref program, reordered, "definition", []);
    let arg: WirValueID = program.arena.functions[wir_id_index(UInt32(reordered))].parameters[0];
    jump(ref program, entry, definition);
    let late: WirValueID = wir_binary(ref program, definition, WirOpcode.Add, i32, arg, one, "late", no_wir_location());
    jump(ref program, definition, use);
    wir_return(ref program, use, late, no_wir_location());

    // the next block in layout has two incoming paths, it must read its home.
    let diamond: WirFuncID = wir_add_function(ref program, "diamond", [wir_param("choose", program.bool_type)], i32, false, WirLinkage.Exported, WirABI.C);
    entry = wir_add_block(ref program, diamond, "entry", []);
    let left: WirBlockID = wir_add_block(ref program, diamond, "left", []);
    let join: WirBlockID = wir_add_block(ref program, diamond, "join", []);
    arg = program.arena.functions[wir_id_index(UInt32(diamond))].parameters[0];
    let kept: WirValueID = wir_binary(ref program, entry, WirOpcode.Add, i32, one, wir_const_int(ref program, i32, UInt128(41U)), "kept", no_wir_location());
    wir_append(ref program, entry, WirOpcode.Branch, program.void_type, [arg], [wir_edge(left, []), wir_edge(join, [])], no_wir_location());
    jump(ref program, left, join);
    wir_return(ref program, join, kept, no_wir_location());

    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(diamond))];
    let preds: Dict(UInt32, Int) = a64_predecessor_counts(ref program, function.blocks);
    if (a64_carry_to_next(ref program, function.blocks, preds, 0) ||
        a64_carry_to_next(ref program, function.blocks, preds, 1)) {
        print("FAIL: AArch64 join inherited one predecessor's registers");
        return 1;
    }

    // body -> latch carries the current iteration, a call must save it before the back edge.
    let clobber: WirFuncID = wir_add_function(ref program, "host_clobber", [], i32, false, WirLinkage.External, WirABI.C);
    let loop: WirFuncID = wir_add_function(ref program, "loop_value", [], i32, false, WirLinkage.Exported, WirABI.C);
    entry = wir_add_block(ref program, loop, "entry", []);
    let header: WirBlockID = wir_add_block(ref program, loop, "header", [wir_param("index", i32)]);
    let body: WirBlockID = wir_add_block(ref program, loop, "body", []);
    let latch: WirBlockID = wir_add_block(ref program, loop, "latch", []);
    let exit: WirBlockID = wir_add_block(ref program, loop, "exit", []);
    let step: WirValueID = wir_binary(ref program, entry, WirOpcode.Add, i32, one, one, "step", no_wir_location());
    wir_append(ref program, entry, WirOpcode.Jump, program.void_type, [],
               [wir_edge(header, [wir_const_int(ref program, i32, UInt128(0U))])], no_wir_location());
    let index: WirValueID = program.arena.blocks[wir_id_index(UInt32(header))].parameters[0];
    let less: WirValueID = wir_binary(ref program, header, WirOpcode.SignedLess, program.bool_type,
                                    index, wir_const_int(ref program, i32, UInt128(1000U)), "less", no_wir_location());
    wir_append(ref program, header, WirOpcode.Branch, program.void_type, [less],
               [wir_edge(body, []), wir_edge(exit, [])], no_wir_location());
    let next: WirValueID = wir_binary(ref program, body, WirOpcode.Add, i32, index, step, "next", no_wir_location());
    jump(ref program, body, latch);
    wir_call(ref program, latch, wir_function_value(ref program, clobber), [], "clobber", no_wir_location());
    wir_append(ref program, latch, WirOpcode.Jump, program.void_type, [], [wir_edge(header, [next])], no_wir_location());
    wir_return(ref program, exit, index, no_wir_location());

    function = program.arena.functions[wir_id_index(UInt32(loop))];
    preds = a64_predecessor_counts(ref program, function.blocks);
    if (!a64_carry_to_next(ref program, function.blocks, preds, 2) ||
        a64_carry_to_next(ref program, function.blocks, preds, 3)) {
        print("FAIL: AArch64 loop edge has an invalid register contract");
        return 1;
    }

    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: cross-block WIR: ", errors[0]);
        return 1;
    }

    let lowered: A64ModuleResult = a64_lower_module(ref program);
    if (lowered.errors.length() != 0) {
        print("FAIL: AArch64 cross-block lowering: ", lowered.errors[0]);
        return 1;
    }

    let bytes: Vector(Byte) = a64_elf_object(A64Object(sections=lowered.sections, symbols=lowered.symbols, relocations=lowered.relocations))?;
    catch(err) { return 1; }
    let object: file.File = file.create("a64_cross_block.o")?;
    catch(err) { return 1; }
    object.write_bytes(bytes)?;
    catch(err) { return 1; }
    object.close();

    print("PASS: AArch64 cross-block registers");
    return 0;
}
