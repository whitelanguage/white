// src/compiler/machine/x86_64/edges.wl
import * from "model.wl"
import * from "../../wir/model.wl"
import * from "encoder.wl"
import * from "allocator.wl"
import * from "memory.wl"
import * from "abi.wl"
import * from "sse.wl"
import * from "abi/sysv.wl"
import x86_address_symbol, x86_emit_globals from "data.wl"
import * from "stack.wl"
import * from "types.wl"
import * from "values.wl"


struct X86EdgeCopy(destination: X86Register, source: X86Register, offset: Int, size: Int, signed: Bool)

func x86_repair_edge(copies: Vector(X86EdgeCopy), ref output: X86CodeBuffer) -> String {
// at most one copy per allocatable register. Emit a destination only after
    // every reader of its old contents has moved away. The homes were written
    // before this list was built, so a cycle needs no reserved scratch register.
    let remaining: Int = copies.length();
    while (remaining != 0) {
        let progress: Bool = false;
        let i = 0;
        while (i < copies.length()) {
            let move: X86EdgeCopy = copies[i];
            if (move.destination == X86Register.None) {
                i++;
                continue;
            }
            let blocked: Bool = false;
            let j = 0;
            while (j < copies.length()) {
                if (j != i && copies[j].destination != X86Register.None && copies[j].source == move.destination) {
                    blocked = true;
                    break;
                }
                j++;
            }
            if (!blocked || move.source == move.destination) {
                if (move.source == X86Register.None) {
                    if (!x86_load_scalar(ref output, move.destination, X86Register.RBP, move.offset, move.size, move.signed)) {
                        return "cannot reload an edge argument";
                    }
                } else if (move.source != move.destination && !x86_move_scalar(ref output, move.destination, move.source, move.size)) {
                    return "cannot move an edge argument";
                }
                move.destination = X86Register.None;
                copies[i] = move;
                remaining--;
                progress = true;
            }
            i++;
        }
        if (!progress) {
            i = 0;
            while (i < copies.length()) {
                if (copies[i].destination != X86Register.None) {
                    let move: X86EdgeCopy = copies[i];
                    move.source = X86Register.None;
                    copies[i] = move;
                    break;
                }
                i++;
            }
        }
    }
    return "";
}

func x86_emit_register_edge(
    ref program: WirModule,
    ref function: WirFunction,
    edge: WirEdge,
    target: WirBlock,
    slots: Vector(X86StackSlot),
    ref state: X86BlockState,
    ref output: X86CodeBuffer
) -> String {
// forward target homes are distinct from every source home. Keep these
    // copies valid even if a later call or eviction discards the entry registers.
    let i = 0;
    while (i < edge.arguments.length()) {
        let offset: Int = x86_stack_offset(ref state.stack, target.parameters[i]);
        if (offset == 0) {
            return "register block parameter has no assigned home";
        }
        let message: String = x86_store_value(ref program, ref function, edge.arguments[i], X86Register.RBP, offset, slots, ref state, ref output);
        if (message.length() != 0) { return message; }
        i++;
    }

    let copies: Vector(X86EdgeCopy) = [];
    i = 0;
    while (i < edge.arguments.length()) {
        let param: WirValueID = target.parameters[i];
        let type_id: WirTypeID = program.arena.values[wir_id_index(UInt32(param))].type_id;
        copies.append(X86EdgeCopy(
            destination=x86_incoming_register(ref state.registers.uses, param),
            source=x86_register_for(ref state.registers, edge.arguments[i]),
            offset=x86_stack_offset(ref state.stack, param),
            size=x86_scalar_size(ref program, type_id),
            signed=x86_scalar_signed(ref program, type_id)
        ));
        i++;
    }
    return x86_repair_edge(copies, ref output);
}

func x86_emit_edge_moves(
    ref program: WirModule,
    ref function: WirFunction,
    edge: WirEdge,
    slots: Vector(X86StackSlot),
    scratch: Vector(Int),
    state: X86BlockState,
    ref output: X86CodeBuffer
) -> String {
    let target_index: Int = wir_id_index(UInt32(edge.target));
    if (target_index < 0 || target_index >= program.arena.blocks.length()) {
        return "edge refers to an unknown basic block";
    }

    let target: WirBlock = program.arena.blocks[target_index];
    if (target.parameters.length() != edge.arguments.length()) {
        return "edge argument count does not match the target block";
    }

    if (edge.arguments.length() > scratch.length()) {
        return "edge transfer exceeds the reserved scratch area";
    }
    if (edge.arguments.length() == 0) {
        return "";
    }

    // both arms start with the same bindings. A spill made in one arm does not
    // magically exist when lowering the other arm.
    let registers: Vector(X86RegisterBinding) = [];
    let binding_index = 0;
    while (binding_index < state.registers.bindings.length()) {
        registers.append(state.registers.bindings[binding_index]);
        binding_index++;
    }
    let wide_low: Vector(X86Register) = [];
    let wide_high: Vector(X86Register) = [];
    binding_index = 0;
    while (binding_index < state.registers.wide_low.length()) {
        wide_low.append(state.registers.wide_low[binding_index]);
        wide_high.append(state.registers.wide_high[binding_index]);
        binding_index++;
    }
    state.registers = X86RegisterPlan(uses=state.registers.uses, bindings=registers, wide_low=wide_low, wide_high=wide_high);
    state.spills = x86_copy_spill_plan(ref state.spills);

    if (x86_incoming_register(ref state.registers.uses, target.parameters[0]) != X86Register.None) {
        return x86_emit_register_edge(ref program, ref function, edge, target, slots, ref state, ref output);
    }

    // read every source first, writing a target early breaks swaps and loop values
    let i = 0;
    while (i < edge.arguments.length()) {
        let message = x86_store_value(ref program, ref function, edge.arguments[i], X86Register.RBP, scratch[i], slots, ref state, ref output);
        if (message.length() != 0) { return message; }
        i++;
    }

    i = 0;
    while (i < target.parameters.length()) {
        let offset: Int = x86_stack_offset(ref state.stack, target.parameters[i]);
        if (offset == 0) {
            return "target block parameter has no assigned location";
        }

        let target_value: WirValue = program.arena.values[wir_id_index(UInt32(target.parameters[i]))];
        let size: Int = x86_scalar_size(ref program, target_value.type_id);
        if (x86_memory_value(ref program, target_value.type_id)) {
            let layout = state.layouts[wir_id_index(UInt32(target_value.type_id))];
            if (!x86_copy_memory(ref output, X86Register.RBP, offset, X86Register.RBP, scratch[i], Int(layout.size), X86Register.RAX)) {
                return "cannot copy aggregate block parameter";
            }
        } else {
            if (size == 0) {
                return "target block parameter is not a supported scalar value";
            }
            x86_load_scalar(ref output, X86Register.RAX, X86Register.RBP, scratch[i], size, x86_scalar_signed(ref program, target_value.type_id));
            x86_store_scalar(ref output, X86Register.RAX, X86Register.RBP, offset, size);
        }
        i++;
    }
    return "";
}
