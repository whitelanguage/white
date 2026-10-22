// src/compiler/machine/aarch64/stack.wl
import * from "../../wir/model.wl"
import * from "allocator.wl"
import A64Register from "model.wl"
import * from "abi.wl"
import * from "flow.wl"
import * from "types.wl"
import * from "../homes.wl"


struct A64StackSlot(value: WirValueID, offset: Int, size: Int)

struct A64StackIndex(
    slots: Vector(A64StackSlot),
    base: Int,
    indices: Vector(Int),
    sparse: Dict(UInt32, Int)
)


func a64_stack_index(slots: Vector(A64StackSlot), range: A64ValueRange) -> A64StackIndex {
// zero denotes a missing slot, SP+0 is a valid home after the outgoing arguments
    let indices: Vector(Int) = [];
    let sparse: Dict(UInt32, Int) = null;
    let count = stack_index_count(range.count, slots.length());

    let i = 0;
    while (i < count) {
        indices.append(0);
        i++;
    }

    i = 0;
    while (i < slots.length()) {
        let local = wir_id_index(UInt32(slots[i].value)) - range.base;
        if (local >= 0 && local < count) {
            indices[local] = i + 1;
        } else {
            if (sparse is null) { sparse = Dict(); }
            sparse.put(UInt32(slots[i].value), i + 1);
        }
        i++;
    }

    return A64StackIndex(slots=slots, base=range.base, indices=indices, sparse=sparse);
}

func a64_find_stack_slot(stack: A64StackIndex, value: WirValueID) -> A64StackSlot {
    let local = wir_id_index(UInt32(value)) - stack.base;
    let index = 0;
    if (local >= 0 && local < stack.indices.length()) {
        index = stack.indices[local];
    } else if (stack.sparse is !null) {
        index = stack.sparse.get(UInt32(value))?;
        catch(err) { index = 0; }
    }

    if (index <= 0 || index > stack.slots.length()) {
        return A64StackSlot(value=NO_WIR_VALUE, offset=0, size=0);
    }
    return stack.slots[index - 1];
}


func a64_pinned_homes(ref program: WirModule, order: Vector(WirBlockID)) -> Dict(UInt32, Bool) {
// block-local intervals cannot describe loop live-outs or the lifetime of an escaped address
    let definitions: Dict(UInt32, UInt32) = Dict();
    let pinned: Dict(UInt32, Bool) = Dict();
    let i = 0;
    while (i < order.length()) {
        let block = program.arena.blocks[wir_id_index(UInt32(order[i]))];
        let j = 0;
        while (j < block.instructions.length()) {
            let inst = program.arena.instructions[wir_id_index(UInt32(block.instructions[j]))];
            if (inst.result != NO_WIR_VALUE) { definitions.put(UInt32(inst.result), UInt32(order[i])); }
            j++;
        }
        i++;
    }

    i = 0;
    while (i < order.length()) {
        let block = program.arena.blocks[wir_id_index(UInt32(order[i]))];
        let j = 0;
        while (j < block.instructions.length()) {
            let inst = program.arena.instructions[wir_id_index(UInt32(block.instructions[j]))];
            let k = 0;
            while (k < inst.operands.length()) {
                let value = UInt32(inst.operands[k]);
                let owner = 0U;
                owner = definitions.get(value)?;
                catch(err) { owner = 0U; }
                if (owner != 0U && owner != UInt32(order[i])) { pinned.put(value, true); }
                if (inst.opcode == WirOpcode.FieldAddress || inst.opcode == WirOpcode.IndexAddress ||
                    inst.opcode == WirOpcode.Bitcast) {
                    pinned.put(value, true);
                }
                k++;
            }

            k = 0;
            while (k < inst.edges.length()) {
                let a = 0;
                while (a < inst.edges[k].arguments.length()) {
                    let value = UInt32(inst.edges[k].arguments[a]);
                    let owner = 0U;
                    owner = definitions.get(value)?;
                    catch(err) { owner = 0U; }
                    if (owner != 0U && owner != UInt32(order[i])) { pinned.put(value, true); }
                    a++;
                }
                k++;
            }
            j++;
        }
        i++;
    }
    return pinned;
}

struct A64StackLayout(
    storage: A64StackIndex,
    homes: A64StackIndex,
    frame_size: Int,
    result_pointer_offset: Int,
    edge_scratch: Vector(Int),
    spills: Vector(Int),
    message: String
)

func a64_edge_scratch_sizes(ref program: WirModule, order: Vector(WirBlockID), layouts: Vector(WirTypeLayout), ref uses: A64UseTable) -> Vector(Int) {
    let sizes: Vector(Int) = [];
    let i = 0;
    while (i < order.length()) {
        let block = program.arena.blocks[wir_id_index(UInt32(order[i]))];
        if (block.instructions.length() != 0) {
            let term = program.arena.instructions[wir_id_index(UInt32(block.instructions[block.instructions.length() - 1]))];
            let j = 0;
            while (j < term.edges.length()) {
                let target = program.arena.blocks[wir_id_index(UInt32(term.edges[j].target))];
                if (target.parameters.length() != 0 && a64_incoming_register(ref uses, target.parameters[0]) == A64Register.None) {
                    let k = 0;
                    while (k < target.parameters.length()) {
                        let type = program.arena.values[wir_id_index(UInt32(target.parameters[k]))].type_id;
                        let bytes = a64_stack_value_size(ref program, type, layouts);
                        if (bytes <= 0) { return [-1]; }
                        if (k == sizes.length()) { sizes.append(0); }
                        if (bytes > sizes[k]) { sizes[k] = bytes; }
                        k++;
                    }
                }
                j++;
            }
        }
        i++;
    }
    return sizes;
}

func a64_outgoing_stack(ref program: WirModule, ref function: WirFunction, layouts: Vector(WirTypeLayout)) -> Int {
    let maximum: Int = 0;
    let i: Int = 0;
    while (i < function.blocks.length()) {
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(function.blocks[i]))];
        let j: Int = 0;
        while (j < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[j]))];
            if (instruction.opcode == WirOpcode.Call && instruction.call_type != NO_WIR_TYPE) {
                let call_type: WirType = program.arena.types[wir_id_index(UInt32(instruction.call_type))];
                let state: A64ArgumentState = A64ArgumentState(integer=0, floating=0, stack=0);
                let arg: Int = 0;
                while (arg < call_type.parameters.length()) {
                    let location: A64ArgumentLocation = a64_argument_location(ref program, call_type.parameters[arg], layouts, ref state);
                    if (!location.valid) { return -1; }
                    arg++;
                }
                if (state.stack > maximum) { maximum = state.stack; }
            }
            j++;
        }
        i++;
    }

    return a64_align(maximum, 16);
}

func a64_stack_error(message: String) -> A64StackLayout {
    let empty = a64_stack_index([], A64ValueRange(base=0, count=0));
    return A64StackLayout(storage=empty, homes=empty, frame_size=0, result_pointer_offset=-1, edge_scratch=[], spills=[], message=message);
}

func a64_stack_layout(ref program: WirModule, ref function: WirFunction, layouts: Vector(WirTypeLayout)) -> A64StackLayout {
    let uses = a64_collect_uses(ref program, function.blocks);
    a64_mark_edge_registers(ref program, function.blocks, ref uses);
    return a64_stack_layout_with_uses(ref program, ref function, layouts, uses);
}

func a64_stack_layout_with_uses(ref program: WirModule, ref function: WirFunction, layouts: Vector(WirTypeLayout), uses: A64UseTable) -> A64StackLayout {
// addressed storage and live-outs have fixed homes, only block-local SSA lifetimes enter the pool
    let storage: Vector(A64StackSlot) = [];
    let homes: Vector(A64StackSlot) = [];
    let seen: Dict(UInt32, Bool) = Dict();
    let pinned = a64_pinned_homes(ref program, function.blocks);
    let pool: StackHomes = StackHomes(size=a64_outgoing_stack(ref program, ref function, layouts), regions=[], free=Dict(), ends=[]);
    if (pool.size < 0) { return a64_stack_error("AArch64 call has an unsupported argument type"); }

    let result_pointer_offset = -1;
    let signature = program.arena.types[wir_id_index(UInt32(function.type_id))];
    let result_index = wir_id_index(UInt32(signature.result));
    if (result_index >= 0 && result_index < layouts.length()) {
        let result_type = program.arena.types[result_index];
        let result_layout = layouts[result_index];
        let hfa = a64_hfa_type(ref program, signature.result, layouts);
        if ((result_type.kind == WirTypeKind.Struct || result_type.kind == WirTypeKind.Array) &&
            result_layout.valid && result_layout.size > 16UL && !hfa.valid) {
            result_pointer_offset = stack_reserve(ref pool, 8, 8);
            if (result_pointer_offset < 0) { return a64_stack_error("AArch64 stack frame is too large"); }
        }
    }

    let scratch: Vector(Int) = [];
    let sizes = a64_edge_scratch_sizes(ref program, function.blocks, layouts, ref uses);
    let i = 0;
    while (i < sizes.length()) {
        let offset = stack_reserve(ref pool, sizes[i], 16);
        if (offset < 0) { return a64_stack_error("AArch64 edge scratch area is too large"); }
        scratch.append(offset);
        i++;
    }

    i = 0;
    while (i < function.parameters.length()) {
        let param = function.parameters[i];
        let type = program.arena.values[wir_id_index(UInt32(param))].type_id;
        let bytes = a64_stack_value_size(ref program, type, layouts);
        if (bytes == 0) { return a64_stack_error("AArch64 parameter home has an unsupported type"); }
        let offset = stack_reserve(ref pool, bytes, a64_stack_value_alignment(type, layouts, bytes));
        if (offset < 0) { return a64_stack_error("AArch64 stack frame is too large"); }

        homes.append(A64StackSlot(value=param, offset=offset, size=bytes));
        i++;
    }

    let position = 0;
    let scalar_results = false;
    i = 0;
    while (i < function.blocks.length()) {
        let block = program.arena.blocks[wir_id_index(UInt32(function.blocks[i]))];
        stack_begin_block(ref pool, block.instructions.length());

        let param_index = 0;
        while (param_index < block.parameters.length()) {
            let param = block.parameters[param_index];
            let type = program.arena.values[wir_id_index(UInt32(param))].type_id;
            let bytes = a64_stack_value_size(ref program, type, layouts);
            if (bytes == 0) { return a64_stack_error("AArch64 block parameter home has an unsupported type"); }
            let offset = stack_reserve(ref pool, bytes, a64_stack_value_alignment(type, layouts, bytes));
            if (offset < 0) { return a64_stack_error("AArch64 stack frame is too large"); }

            homes.append(A64StackSlot(value=param, offset=offset, size=bytes));
            param_index++;
        }

        let j = 0;
        while (j < block.instructions.length()) {
            stack_expire(ref pool, j);
            let inst = program.arena.instructions[wir_id_index(UInt32(block.instructions[j]))];
            if (inst.opcode == WirOpcode.StackAlloc) {
                let pointer = program.arena.types[wir_id_index(UInt32(inst.type_id))];
                let bytes = 0;
                if (pointer.kind == WirTypeKind.Pointer) {
                    bytes = a64_stack_value_size(ref program, pointer.element, layouts);
                }
                if (inst.result == NO_WIR_VALUE || bytes == 0) {
                    return a64_stack_error("AArch64 stack slot has an unsupported type");
                }

                let offset = stack_reserve(ref pool, bytes, a64_stack_value_alignment(pointer.element, layouts, bytes));
                if (offset < 0) { return a64_stack_error("AArch64 stack frame is too large"); }
                storage.append(A64StackSlot(value=inst.result, offset=offset, size=bytes));
            } else if (inst.result != NO_WIR_VALUE) {
                let bytes = a64_stack_value_size(ref program, inst.type_id, layouts);
                if (a64_scalar_width(ref program, inst.type_id) != 0) { scalar_results = true; }
                let pinned_home = false;
                if (bytes != 0) {
                    pinned_home = pinned.get(UInt32(inst.result))?;
                    catch(err) { pinned_home = false; }
                }
                if (bytes != 0 && (a64_scalar_width(ref program, inst.type_id) == 0 || pinned_home)) {
                    let alignment = a64_stack_value_alignment(inst.type_id, layouts, bytes);
                    let offset = -1;
                    if pinned_home {
                        offset = stack_reserve(ref pool, bytes, alignment);
                    } else {
                        let last = j;
                        let index = a64_use_index(ref uses, inst.result);
                        if (index >= 0 && index < uses.queues.length()) {
                            let queue = uses.queues[index];
                            if (queue.positions.length() != 0) {
                                last += queue.positions[queue.positions.length() - 1] - position;
                            }
                        }
                        offset = stack_reuse(ref pool, bytes, alignment, last);
                    }
                    if (offset < 0) { return a64_stack_error("AArch64 stack home has an invalid lifetime or frame size"); }
                    homes.append(A64StackSlot(value=inst.result, offset=offset, size=bytes));
                }
            }

            let operand_index = 0;
            while (operand_index < inst.operands.length()) {
                let operand = inst.operands[operand_index];
                let value = program.arena.values[wir_id_index(UInt32(operand))];
                let recorded = false;
                if (value.kind == WirValueKind.Constant) {
                    recorded = seen.get(UInt32(operand))?;
                    catch(err) { recorded = false; }
                }
                if (value.kind == WirValueKind.Constant && !recorded && a64_aggregate_type(ref program, value.type_id)) {
                    let bytes = a64_stack_value_size(ref program, value.type_id, layouts);
                    if (bytes == 0) { return a64_stack_error("AArch64 aggregate constant has an unsupported type"); }
                    let offset = stack_reserve(ref pool, bytes, a64_stack_value_alignment(value.type_id, layouts, bytes));
                    if (offset < 0) { return a64_stack_error("AArch64 stack frame is too large"); }

                    homes.append(A64StackSlot(value=operand, offset=offset, size=bytes));
                    seen.put(UInt32(operand), true);
                }
                operand_index++;
            }
            position++;
            j++;
        }
        stack_expire(ref pool, block.instructions.length());
        i++;
    }

    // scalar homes are claimed on eviction, keep enough space for live values
    // at calls and the temporary needed before an instruction releases its inputs.
    let spill_count = a64_spill_capacity(ref program, function.blocks, ref uses, 7);
    if scalar_results { spill_count += 3; }
    let spills: Vector(Int) = [];
    for (let s = 0; s < spill_count; s++) {
        let offset = stack_reserve(ref pool, 8, 8);
        if (offset < 0) { return a64_stack_error("AArch64 spill area is too large"); }
        spills.append(offset);
    }

    if (pool.size > 2147483632) { return a64_stack_error("AArch64 stack frame is too large"); }
    let range = a64_function_value_range(ref program, function.blocks);
    return A64StackLayout(storage=a64_stack_index(storage, range), homes=a64_stack_index(homes, range),
        frame_size=a64_align(pool.size, 16), result_pointer_offset=result_pointer_offset, edge_scratch=scratch, spills=spills, message="");
}
