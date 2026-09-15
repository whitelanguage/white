// compiler/machine/x86_64/lowering.wl
import * from "model.wl"
import * from "encoder.wl"
import * from "abi.wl"
import * from "../../wir/model.wl"
import wir_type_layout from "../../wir/layout.wl"

struct X86LoweringResult(
    bytes: Vector(Byte),
    errors: Vector(String)
)

struct X86StackSlot(
    value: WirValueID,
    offset: Int,
    size: Int
)

struct X86BlockOffset(
    block: WirBlockID,
    offset: Int
)

struct X86BranchFixup(
    offset: Int,
    target: WirBlockID
)

struct X86BlockState(
    accumulator: WirValueID,
    flags_value: WirValueID,
    flags_opcode: X86Opcode,
    message: String
)

func x86_lowering_error(message: String) -> X86LoweringResult {
    return X86LoweringResult(bytes=[], errors=[message]);
}

func x86_lower_return(program: WirModule, instruction: WirInstruction, frame_size: Int, ref output: X86CodeBuffer) -> Bool {
    if (instruction.operands.length() == 0) {
        if (frame_size > 0) {
            x86_frame_leave(ref output);
        }

        x86_return(ref output);
        return true;
    }

    if (instruction.operands.length() != 1) {
        return false;
    }

    let value: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
    if (value.kind != WirValueKind.Integer) { return false; }
    let type: WirType = program.arena.types[wir_id_index(UInt32(value.type_id))];
    if (type.kind != WirTypeKind.SignedInt && type.kind != WirTypeKind.UnsignedInt) {
        return false;
    }

    if (type.bits <= 32) {
        x86_mov_eax_imm32(ref output, UInt32(value.integer));
    } else if (type.bits <= 64) {
        x86_mov_rax_imm64(ref output, UInt64(value.integer));
    } else {
        return false;
    }
    if (frame_size > 0) {
        x86_frame_leave(ref output);
    }

    x86_return(ref output);
    return true;
}

func x86_parameter_index(function: WirFunction, value_id: WirValueID) -> Int {
    let i: Int = 0;
    while (i < function.parameters.length()) {
        if (function.parameters[i] == value_id) { return i; }
        i += 1;
    }
    return -1;
}

func x86_is_i32_integer(program: WirModule, type_id: WirTypeID) -> Bool {
    let type: WirType = program.arena.types[wir_id_index(UInt32(type_id))];
    return (type.kind == WirTypeKind.SignedInt    || 
            type.kind == WirTypeKind.UnsignedInt) && 
            type.bits <= 32;
}

func x86_lower_parameter_to_eax(program: WirModule, function: WirFunction, value_id: WirValueID, ref output: X86CodeBuffer) -> Bool {
    let index: Int = x86_parameter_index(function, value_id);
    if (index < 0 || index >= 4) {
        return false;
    }

    if (!x86_is_i32_integer(program, program.arena.values[wir_id_index(UInt32(value_id))].type_id)) {
        return false;
    }

    let register: X86Register = x86_win64_argument_register(index, false);
    if (register == X86Register.None) {
        return false;
    }

    x86_mov_eax_register32(ref output, register);
    return true;
}

func x86_align_frame_offset(value: Int, alignment: Int) -> Int {
    if (alignment <= 1) {
        return value;
    }

    let remainder: Int = value % alignment;
    if (remainder == 0) {
        return value;
    }

    return value + alignment - remainder;
}

func x86_block_order(function: WirFunction) -> Vector(WirBlockID) {
    let order: Vector(WirBlockID) = [];
    if (function.entry != NO_WIR_BLOCK) {
        order.append(function.entry);
    }

    let i = 0;
    while (i < function.blocks.length()) {
        if (function.blocks[i] != function.entry) {
            order.append(function.blocks[i]);
        }

        i++;
    }

    return order;
}

func x86_collect_stack_slots(program: WirModule, order: Vector(WirBlockID)) -> Vector(X86StackSlot) {
    let slots: Vector(X86StackSlot) = [];
    let offset = 0;
    let block_index = 0;
    while (block_index < order.length()) {
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(order[block_index]))];

        let i = 0;
        while (i < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[i]))];
            if (instruction.opcode == WirOpcode.StackAlloc && instruction.result != NO_WIR_VALUE) {
                let pointer: WirType = program.arena.types[wir_id_index(UInt32(instruction.type_id))];
                if (pointer.kind != WirTypeKind.Pointer) {
                    return [];
                }

                let layout: WirTypeLayout = wir_type_layout(program, pointer.element);
                if (!layout.valid || layout.size == 0UL || layout.size > 2147483647UL) {
                    return [];
                }

                offset = x86_align_frame_offset(offset + Int(layout.size), layout.alignment);
                slots.append(X86StackSlot(value=instruction.result, offset=offset, size=Int(layout.size)));
            }
            i++;
        }

        i = 0;
        while (i < block.parameters.length()) {
            let parameter: WirValue = program.arena.values[wir_id_index(UInt32(block.parameters[i]))];
            if (!x86_is_i32_integer(program, parameter.type_id)) { return []; }
            offset = x86_align_frame_offset(offset + 4, 4);
            slots.append(X86StackSlot(value=block.parameters[i], offset=offset, size=4));
            i++;
        }

        block_index++;
    }
    return slots;
}

func x86_stack_offset(slots: Vector(X86StackSlot), value: WirValueID) -> Int {
    let i = 0;
    while (i < slots.length()) {
        if (slots[i].value == value) {
            return 0 - slots[i].offset;
        }

        i++;
    }
    return 0;
}

func x86_edge_scratch_count(program: WirModule, order: Vector(WirBlockID)) -> Int {
    let count: Int = 0;
    let block_index: Int = 0;
    while (block_index < order.length()) {
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(order[block_index]))];

        let instruction_index: Int = 0;
        while (instruction_index < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[instruction_index]))];
            let edge_index: Int = 0;
            while (edge_index < instruction.edges.length()) {
                if (instruction.edges[edge_index].arguments.length() > count) {
                    count = instruction.edges[edge_index].arguments.length();
                }
                edge_index += 1;
            }

            instruction_index += 1;
        }

        block_index += 1;
    }
    return count;
}

func x86_edge_scratch(slots: Vector(X86StackSlot), count: Int) -> Vector(Int) {
    let offsets: Vector(Int) = [];
    let offset: Int = 0;
    if (slots.length() != 0) {
        offset = slots[slots.length() - 1].offset;
    }

    let i = 0;
    while (i < count) {
        offset = x86_align_frame_offset(offset + 4, 4);
        offsets.append(0 - offset);
        i++;
    }

    return offsets;
}

func x86_stack_frame_size(slots: Vector(X86StackSlot), scratch: Vector(Int)) -> Int {
    let size: Int = 0;
    if (slots.length() != 0) {
        size = slots[slots.length() - 1].offset;
    }

    if (scratch.length() != 0 && 0 - scratch[scratch.length() - 1] > size) {
        size = 0 - scratch[scratch.length() - 1];
    }

    return x86_align_frame_offset(size, 16);
}

func x86_lower_value_to_eax(program: WirModule, function: WirFunction, value_id: WirValueID, accumulator: WirValueID, slots: Vector(X86StackSlot), ref output: X86CodeBuffer) -> Bool {
    if (value_id == accumulator) {
        return true;
    }

    let value: WirValue = program.arena.values[wir_id_index(UInt32(value_id))];
    if (value.kind == WirValueKind.Integer) {
        let type: WirType = program.arena.types[wir_id_index(UInt32(value.type_id))];
        if ((type.kind != WirTypeKind.SignedInt && type.kind != WirTypeKind.UnsignedInt)
            || type.bits > 32) {
            return false;
        }

        x86_mov_eax_imm32(ref output, UInt32(value.integer));
        return true;
    }

    if (value.kind == WirValueKind.FunctionParameter) {
        return x86_lower_parameter_to_eax(program, function, value_id, ref output);
    }

    if (value.kind == WirValueKind.BlockParameter) {
        let offset: Int = x86_stack_offset(slots, value_id);
        if (offset == 0) {
            return false;
        }

        x86_load_eax_rbp_disp32(ref output, offset);
        return true;
    }
    return false;
}

func x86_comparison_opcode(opcode: WirOpcode) -> X86Opcode {
    if (opcode == WirOpcode.Equal) { return X86Opcode.Je; }
    if (opcode == WirOpcode.NotEqual) { return X86Opcode.Jne; }
    if (opcode == WirOpcode.SignedLess) { return X86Opcode.Jl; }
    if (opcode == WirOpcode.SignedLessEqual) { return X86Opcode.Jle; }
    if (opcode == WirOpcode.SignedGreater) { return X86Opcode.Jg; }
    if (opcode == WirOpcode.SignedGreaterEqual) { return X86Opcode.Jge; }
    if (opcode == WirOpcode.UnsignedLess) { return X86Opcode.Jb; }
    if (opcode == WirOpcode.UnsignedLessEqual) { return X86Opcode.Jbe; }
    if (opcode == WirOpcode.UnsignedGreater) { return X86Opcode.Ja; }
    if (opcode == WirOpcode.UnsignedGreaterEqual) { return X86Opcode.Jae; }
    return X86Opcode.Invalid;
}

func x86_block_offset(offsets: Vector(X86BlockOffset), block: WirBlockID) -> Int {
    let i = 0;
    while (i < offsets.length()) {
        if (offsets[i].block == block) {
            return offsets[i].offset;
        }

        i++;
    }

    return -1;
}

func x86_patch_branches(ref output: X86CodeBuffer, offsets: Vector(X86BlockOffset), fixups: Vector(X86BranchFixup)) -> Bool {
    let i = 0;
    while (i < fixups.length()) {
        let target: Int = x86_block_offset(offsets, fixups[i].target);
        if (target < 0) {
            return false;
        }

        let displacement: Int = target - (fixups[i].offset + 4);
        if (displacement < -2147483648 || displacement > 2147483647) {
            return false;
        }

        if (!x86_patch_i32(ref output, fixups[i].offset, displacement)) {
            return false;
        }

        i++;
    }

    return true;
}

func x86_instruction_error(state: X86BlockState, message: String) -> X86BlockState {
    state.message = message;
    return state;
}

func x86_emit_edge_moves(program: WirModule, function: WirFunction, edge: WirEdge, slots: Vector(X86StackSlot), scratch: Vector(Int), accumulator: WirValueID, ref output: X86CodeBuffer) -> String {
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

    // stage every source before writing a target, this keeps swaps and loop-carried values correct
    let i = 0;
    while (i < edge.arguments.length()) {
        if (!x86_lower_value_to_eax(program, function, edge.arguments[i], accumulator, slots, ref output)) {
            return "the x86_64 lowering cannot move this edge argument";
        }
        x86_store_eax_rbp_disp32(ref output, scratch[i]);
        i++;
    }

    i = 0;
    while (i < target.parameters.length()) {
        let offset: Int = x86_stack_offset(slots, target.parameters[i]);
        if (offset == 0) {
            return "target block parameter has no assigned location";
        }

        x86_load_eax_rbp_disp32(ref output, scratch[i]);
        x86_store_eax_rbp_disp32(ref output, offset);

        i++;
    }
    return "";
}

func x86_lower_instruction(program: WirModule, function: WirFunction, 
                           instruction: WirInstruction, slots: Vector(X86StackSlot), 
                           scratch: Vector(Int), frame_size: Int, state: X86BlockState, 
                           ref output: X86CodeBuffer, ref fixups: Vector(X86BranchFixup)) -> X86BlockState {

    if (instruction.opcode == WirOpcode.StackAlloc) {
        state.accumulator = NO_WIR_VALUE;
        return state;
    }

    if (instruction.opcode == WirOpcode.Store) {
        if (instruction.operands.length() != 2) {
            return x86_instruction_error(state, "store instruction has the wrong operand count");
        }

        let offset: Int = x86_stack_offset(slots, instruction.operands[1]);
        if (offset == 0) {
            return x86_instruction_error(state, "store does not refer to a known stack slot");
        }

        if (!x86_is_i32_integer(program, program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id)) {
            return x86_instruction_error(state, "the initial x86_64 lowering supports 32-bit integer stores");
        }
        if (!x86_lower_value_to_eax(program, function, instruction.operands[0], state.accumulator, slots, ref output)) {
            return x86_instruction_error(state, "the initial x86_64 lowering cannot store this value");
        }

        x86_store_eax_rbp_disp32(ref output, offset);
        state.accumulator = instruction.operands[0];
        return state;
    }

    if (instruction.opcode == WirOpcode.Load) {
        if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
            return x86_instruction_error(state, "load instruction has the wrong operand count");
        }

        let offset: Int = x86_stack_offset(slots, instruction.operands[0]);
        if (offset == 0) {
            return x86_instruction_error(state, "load does not refer to a known stack slot");
        }

        if (!x86_is_i32_integer(program, instruction.type_id)) {
            return x86_instruction_error(state, "the initial x86_64 lowering supports 32-bit integer loads");
        }

        x86_load_eax_rbp_disp32(ref output, offset);
        state.accumulator = instruction.result;
        return state;
    }

    if (instruction.opcode == WirOpcode.Add || instruction.opcode == WirOpcode.Subtract || instruction.opcode == WirOpcode.Multiply) {
        if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
            return x86_instruction_error(state, "arithmetic instruction has the wrong operand count");
        }

        let result_type: WirType = program.arena.types[wir_id_index(UInt32(instruction.type_id))];
        if ((result_type.kind != WirTypeKind.SignedInt && result_type.kind != WirTypeKind.UnsignedInt) || result_type.bits > 32) {
            return x86_instruction_error(state, "the initial x86_64 lowering supports 32-bit integer arithmetic");
        }

        let left_id: WirValueID = instruction.operands[0];
        let right: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[1]))];

        if (right.kind != WirValueKind.Integer) {
            return x86_instruction_error(state, "the initial x86_64 lowering requires an integer arithmetic right operand");
        }
        if (!x86_lower_value_to_eax(program, function, left_id, state.accumulator, slots, ref output)) {
            return x86_instruction_error(state, "the initial x86_64 lowering cannot load this arithmetic operand");
        }
        if (instruction.opcode == WirOpcode.Add) {
            x86_add_eax_imm32(ref output, UInt32(right.integer));
        } else if (instruction.opcode == WirOpcode.Subtract) {
            x86_sub_eax_imm32(ref output, UInt32(right.integer));
        } else {
            x86_imul_eax_imm32(ref output, UInt32(right.integer));
        }

        state.accumulator = instruction.result;
        return state;
    }

    let comparison: X86Opcode = x86_comparison_opcode(instruction.opcode);
    if (comparison != X86Opcode.Invalid) {
        if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE || instruction.type_id != program.bool_type) {
            return x86_instruction_error(state, "comparison instruction has an invalid result or operand count");
        }
        let right: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[1]))];
        if (right.kind != WirValueKind.Integer) {
            return x86_instruction_error(state, "the initial x86_64 comparison lowering requires an integer constant on the right");
        }
        if (!x86_lower_value_to_eax(program, function, instruction.operands[0], state.accumulator, slots, ref output)) {
            return x86_instruction_error(state, "the initial x86_64 lowering cannot load this comparison operand");
        }
        x86_cmp_eax_imm32(ref output, UInt32(right.integer));

        state.accumulator = instruction.operands[0];
        state.flags_value = instruction.result;
        state.flags_opcode = comparison;
        return state;
    }

    if (instruction.opcode == WirOpcode.Jump) {
        if (instruction.operands.length() != 0 || instruction.edges.length() != 1) {
            return x86_instruction_error(state, "jump instruction has an unsupported edge shape");
        }

        let move_error: String = x86_emit_edge_moves(program, function, instruction.edges[0], slots, scratch, state.accumulator, ref output);
        if (move_error.length() != 0) {
            return x86_instruction_error(state, move_error);
        }

        fixups.append(X86BranchFixup(offset=x86_jump_rel32(ref output), target=instruction.edges[0].target));
        return state;
    }

    if (instruction.opcode == WirOpcode.Branch) {
        if (instruction.operands.length() != 1 || instruction.edges.length() != 2) {
            return x86_instruction_error(state, "branch instruction has an unsupported edge shape");
        }

        let condition: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
        if (condition.kind == WirValueKind.BoolValue) {
            let edge = 1;
            if (condition.integer != UInt128(0U)) {
                edge = 0;
            }

            let move_error: String = x86_emit_edge_moves(program, function, instruction.edges[edge], slots, scratch, state.accumulator, ref output);
            if (move_error.length() != 0) {
                return x86_instruction_error(state, move_error);
            }

            fixups.append(X86BranchFixup(offset=x86_jump_rel32(ref output), target=instruction.edges[edge].target));
            return state;
        }

        if (instruction.operands[0] != state.flags_value || state.flags_opcode == X86Opcode.Invalid) {
            return x86_instruction_error(state, "the initial x86_64 branch lowering requires a local comparison result");
        }
        if (instruction.edges[0].arguments.length() == 0 && instruction.edges[1].arguments.length() == 0) {
            let direct_patch: Int = x86_jump_if_rel32(ref output, state.flags_opcode);
            if (direct_patch < 0) {
                return x86_instruction_error(state, "the x86_64 encoder rejected the branch condition");
            }

            fixups.append(X86BranchFixup(offset=direct_patch, target=instruction.edges[0].target));
            fixups.append(X86BranchFixup(offset=x86_jump_rel32(ref output), target=instruction.edges[1].target));
            return state;
        }

        let true_patch: Int = x86_jump_if_rel32(ref output, state.flags_opcode);
        if (true_patch < 0) {
            return x86_instruction_error(state, "the x86_64 encoder rejected the branch condition");
        }

        let false_move_error: String = x86_emit_edge_moves(program, function, instruction.edges[1], slots, scratch, state.accumulator, ref output);
        if (false_move_error.length() != 0) {
            return x86_instruction_error(state, false_move_error);
        }

        fixups.append(X86BranchFixup(offset=x86_jump_rel32(ref output), target=instruction.edges[1].target));

        let true_offset: Int = output.bytes.length();
        if (!x86_patch_i32(ref output, true_patch, true_offset - (true_patch + 4))) {
            return x86_instruction_error(state, "the x86_64 lowering could not resolve the true edge transfer");
        }

        let true_move_error: String = x86_emit_edge_moves(program, function, instruction.edges[0], slots, scratch, state.accumulator, ref output);
        if (true_move_error.length() != 0) {
            return x86_instruction_error(state, true_move_error);
        }

        fixups.append(X86BranchFixup(offset=x86_jump_rel32(ref output), target=instruction.edges[0].target));
        return state;
    }

    if (instruction.opcode == WirOpcode.Return) {
        if (instruction.operands.length() == 1 &&
            x86_lower_value_to_eax(program, function, instruction.operands[0], state.accumulator, slots, ref output)) {
            if (frame_size > 0) {
                x86_frame_leave(ref output);
            }

            x86_return(ref output);
            return state;
        }

        if (!x86_lower_return(program, instruction, frame_size, ref output)) {
            return x86_instruction_error(state, "unsupported return operand in the initial x86_64 lowering");
        }
        return state;
    }

    return x86_instruction_error(state, "unsupported instruction in the initial x86_64 lowering");
}

func x86_lower_function(program: WirModule, function_id: WirFuncID) -> X86LoweringResult {
    let function_index: Int = wir_id_index(UInt32(function_id));
    if (function_index < 0 || function_index >= program.arena.functions.length()) {
        return x86_lowering_error("function id is outside the WIR function table");
    }

    let function: WirFunction = program.arena.functions[function_index];
    if (function.linkage == WirLinkage.External) {
        return x86_lowering_error("external functions do not have machine code");
    }
    let order: Vector(WirBlockID) = x86_block_order(function);
    if (order.length() == 0 || order.length() != function.blocks.length()) {
        return x86_lowering_error("the x86_64 lowering could not find the function entry block");
    }

    let located_values: Int = 0;
    let block_index: Int = 0;
    while (block_index < order.length()) {
        let index: Int = wir_id_index(UInt32(order[block_index]));
        if (index < 0 || index >= program.arena.blocks.length()) {
            return x86_lowering_error("function refers to an unknown basic block");
        }

        let block: WirBlock = program.arena.blocks[index];
        if (block.function != function_id) {
            return x86_lowering_error("function refers to a basic block owned by another function");
        }

        if (block.instructions.length() == 0) {
            return x86_lowering_error("the x86_64 lowering requires every basic block to have a terminator");
        }
        located_values += block.parameters.length();

        let instruction_index: Int = 0;
        while (instruction_index < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[instruction_index]))];
            if (instruction.opcode == WirOpcode.StackAlloc) {
                located_values += 1;
            }

            instruction_index += 1;
        }

        block_index += 1;
    }

    let slots: Vector(X86StackSlot) = x86_collect_stack_slots(program, order);
    if (slots.length() != located_values) {
        return x86_lowering_error("the x86_64 lowering could not lay out a stack slot");
    }

    let scratch: Vector(Int) = x86_edge_scratch(slots, x86_edge_scratch_count(program, order));
    let frame_size: Int = x86_stack_frame_size(slots, scratch);
    let output: X86CodeBuffer = x86_new_code_buffer();
    let offsets: Vector(X86BlockOffset) = [];
    let fixups: Vector(X86BranchFixup) = [];
    if (frame_size > 0) {
        x86_frame_enter(ref output, frame_size);
    }

    block_index = 0;
    while (block_index < order.length()) {
        let block_id: WirBlockID = order[block_index];
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(block_id))];
        offsets.append(X86BlockOffset(block=block_id, offset=output.bytes.length()));

        let state: X86BlockState = X86BlockState(accumulator=NO_WIR_VALUE, flags_value=NO_WIR_VALUE, flags_opcode=X86Opcode.Invalid, message="");
        let instruction_index: Int = 0;
        while (instruction_index < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[instruction_index]))];
            state = x86_lower_instruction(program, function, instruction, slots, scratch, frame_size, state, ref output, ref fixups);
            if (state.message.length() != 0) {
                return x86_lowering_error(state.message);
            }

            instruction_index += 1;
        }

        block_index += 1;
    }

    if (!x86_patch_branches(ref output, offsets, fixups)) {
        return x86_lowering_error("the x86_64 lowering could not resolve a branch target");
    }

    return X86LoweringResult(bytes=output.bytes, errors=[]);
}
