// src/compiler/machine/aarch64/edges.wl
import * from "model.wl"
import * from "../../wir/model.wl"
import * from "encoder.wl"
import * from "allocator.wl"
import * from "memory.wl"
import * from "abi.wl"
import * from "fp.wl"
import * from "stack.wl"
import * from "types.wl"
import * from "values.wl"


struct A64EdgeCopy(destination: A64Register, source: A64Register, offset: Int, width: Int, floating: Bool)

func a64_repair_edge(copies: Vector(A64EdgeCopy), ref output: A64CodeBuffer) -> Bool {
// target homes already hold a snapshot, a cycle can reload one source to free its register
    let remaining = copies.length();
    while (remaining != 0) {
        let progress = false;
        let i = 0;
        while (i < copies.length()) {
            let move = copies[i];
            if (move.destination == A64Register.None) {
                i++;
                continue;
            }
            let blocked = false;
            let j = 0;
            while (j < copies.length()) {
                if (j != i && copies[j].destination != A64Register.None && copies[j].source == move.destination) {
                    blocked = true;
                    break;
                }
                j++;
            }
            if (!blocked || move.source == move.destination) {
                let copied = true;
                if (move.source == A64Register.None) {
                    if (move.floating) {
                        copied = a64_load_float_at(ref output, move.destination, A64Register.SP, move.offset, move.width == 64);
                    } else {
                        copied = a64_load_integer_at(ref output, move.destination, A64Register.SP, move.offset, move.width);
                    }
                } else if (move.source != move.destination) {
                    if (move.floating) {
                        copied = a64_float_move(ref output, move.destination, move.source, move.width == 64);
                    } else {
                        copied = a64_mov_register(ref output, move.destination, move.source, move.width == 64);
                    }
                }
                if (!copied) { return false; }
                move.destination = A64Register.None;
                copies[i] = move;
                remaining--;
                progress = true;
            }
            i++;
        }
        if (!progress) {
            i = 0;
            while (i < copies.length()) {
                if (copies[i].destination != A64Register.None) {
                    let move = copies[i];
                    move.source = A64Register.None;
                    copies[i] = move;
                    break;
                }
                i++;
            }
        }
    }
    return true;
}

func a64_stage_edge_arg(ref program: WirModule, arg: WirValueID, offset: Int, stack: A64StackLayout, layouts: Vector(WirTypeLayout), ref values: A64ValueMap, ref output: A64CodeBuffer) -> Bool {
    let type = program.arena.values[wir_id_index(UInt32(arg))].type_id;
    let width = a64_scalar_width(ref program, type);
    if (width != 0) {
        // homes hold normalized scalars, narrow signed integers need all 32 bits.
        let source = a64_materialize_address(ref program, arg, stack.storage, stack.homes, ref values, ref output);
        if (source == A64Register.None) { return false; }
        if (a64_scalar_float(ref program, type)) {
            return a64_store_float_at(ref output, source, A64Register.SP, offset, width == 64);
        }
        return a64_store_integer_at(ref output, source, A64Register.SP, offset, width);
    }
    if (a64_aggregate_type(ref program, type) &&
        !a64_zero_memory(ref output, A64Register.SP, offset, a64_stack_value_size(ref program, type, layouts))) {
        return false;
    }
    return a64_store_value_at(ref program, arg, A64Register.SP, offset, stack.storage, stack.homes, layouts, ref values, ref output);
}

func a64_spill_edge_liveouts(ref program: WirModule, homes: A64StackIndex, ref values: A64ValueMap, ref output: A64CodeBuffer) -> Bool {
// edge-only operands already get snapshots, preserve homes for uses beyond this terminator
    let i = 0;
    while (i < values.bindings.length()) {
        let binding = values.bindings[i];
        if (binding.value != NO_WIR_VALUE &&
            (a64_next_use(ref values.uses, binding.value, values.position) != A64_NO_NEXT_USE ||
             a64_use_precedes_definition(ref values.uses, binding.value, values.position))) {
            if (!a64_spill_binding(ref program, homes, ref values, ref output, i)) { return false; }
        }
        i++;
    }
    return true;
}

func a64_write_edge(ref program: WirModule, edge: WirEdge, stack: A64StackLayout, layouts: Vector(WirTypeLayout), ref values: A64ValueMap, ref output: A64CodeBuffer) -> Bool {
    let block_index: Int = wir_id_index(UInt32(edge.target));
    if (block_index < 0 || block_index >= program.arena.blocks.length()) { return false; }

    let target: WirBlock = program.arena.blocks[block_index];
    if (target.parameters.length() != edge.arguments.length()) { return false; }
    if (target.parameters.length() == 0) { return true; }

    // copying edge registers changes their contents. Commit live-outs before
    // that happens, both branch arms will then start from the same homes.
    if (!a64_spill_edge_liveouts(ref program, stack.homes, ref values, ref output)) { return false; }
    let registers = a64_incoming_register(ref values.uses, target.parameters[0]) != A64Register.None;
    if (!registers && edge.arguments.length() > stack.edge_scratch.length()) { return false; }

    let i: Int = 0;
    while (i < edge.arguments.length()) {
        let offset = 0;
        if registers {
            let home = a64_find_stack_slot(stack.homes, target.parameters[i]);
            if (home.value == NO_WIR_VALUE) { return false; }
            offset = home.offset;
        } else {
            offset = stack.edge_scratch[i];
        }
        if (!a64_stage_edge_arg(ref program, edge.arguments[i], offset, stack, layouts, ref values, ref output)) { return false; }
        i++;
    }

    if registers {
        // forward target parameter homes cannot alias their sources, each
        // source dominates this edge and has a different fixed home.
        let copies: Vector(A64EdgeCopy) = [];
        i = 0;
        while (i < target.parameters.length()) {
            let param = target.parameters[i];
            let type = program.arena.values[wir_id_index(UInt32(param))].type_id;
            copies.append(A64EdgeCopy(destination=a64_incoming_register(ref values.uses, param),
                source=a64_mapped_register(ref values, edge.arguments[i]), offset=a64_find_stack_slot(stack.homes, param).offset,
                width=a64_scalar_width(ref program, type), floating=a64_scalar_float(ref program, type)));
            i++;
        }
        let repaired = a64_repair_edge(copies, ref output);
        // repair has overwritten source registers, their old bindings cannot
        // be spilled by the terminator cleanup. Live-outs were saved above.
        a64_clear_bindings(ref values);
        return repaired;
    }

    // all sources are staged before any target is overwritten, including
    // aggregate and Int128 swaps on a self-edge.
    a64_clear_bindings(ref values);
    i = 0;
    while (i < target.parameters.length()) {
        let home = a64_find_stack_slot(stack.homes, target.parameters[i]);
        if (home.value == NO_WIR_VALUE || !a64_copy_memory(ref output, A64Register.SP, home.offset,
            A64Register.SP, stack.edge_scratch[i], home.size, A64Register.X9)) {
            return false;
        }
        i++;
    }

    return true;
}
