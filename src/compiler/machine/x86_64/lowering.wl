// compiler/machine/x86_64/lowering.wl
import * from "model.wl"
import * from "encoder.wl"
import * from "abi.wl"
import * from "allocator.wl"
import * from "../../wir/model.wl"
import wir_type_layout from "../../wir/layout.wl"


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

struct X86CallFixup(
    offset: Int,
    target: WirFuncID
)

struct X86LoweringResult(
    bytes: Vector(Byte),
    errors: Vector(String),
    calls: Vector(X86CallFixup)
)

struct X86FunctionCode(
    function: WirFuncID,
    offset: Int,
    bytes: Vector(Byte),
    calls: Vector(X86CallFixup)
)

struct X86ModuleResult(
    bytes: Vector(Byte),
    errors: Vector(String),
    relocations: Vector(X86Relocation),
    symbols: Vector(X86Symbol)
)

struct X86BlockState(
    accumulator: WirValueID,
    flags_value: WirValueID,
    flags_opcode: X86Opcode,
    registers: X86RegisterPlan,
    spills: X86SpillPlan,
    position: Int,
    message: String
)

struct X86RegisterResult(
    register: X86Register,
    message: String
)

func x86_lowering_error(message: String) -> X86LoweringResult {
    return X86LoweringResult(bytes=[], errors=[message], calls=[]);
}

func x86_module_error(message: String) -> X86ModuleResult {
    return X86ModuleResult(bytes=[], errors=[message], relocations=[], symbols=[]);
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

func x86_lower_parameter_to_eax(program: WirModule, function: WirFunction, value_id: WirValueID, slots: Vector(X86StackSlot), ref output: X86CodeBuffer) -> Bool {
    let saved_offset: Int = x86_stack_offset(slots, value_id);
    if (saved_offset != 0) {
        x86_load_eax_rbp_disp32(ref output, saved_offset);
        return true;
    }

    let index: Int = x86_parameter_index(function, value_id);
    if (index < 0) {
        return false;
    }

    if (!x86_is_i32_integer(program, program.arena.values[wir_id_index(UInt32(value_id))].type_id)) {
        return false;
    }

    if (index < 4) {
        let register: X86Register = x86_win64_argument_register(index, false);
        if (register == X86Register.None) {
            return false;
        }

        x86_mov_eax_register32(ref output, register);
    } else {
        let offset: Int = x86_win64_stack_param_offset(index);
        if (offset < 0) {
            return false;
        }
    
        x86_load_eax_rbp_disp32(ref output, offset);
    }
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

func x86_collect_stack_slots(program: WirModule, function: WirFunction, order: Vector(WirBlockID), home_params: Bool) -> Vector(X86StackSlot) {
    let slots: Vector(X86StackSlot) = [];
    let offset = 0;
    if home_params {
        let param_index = 0;
        while (param_index < function.parameters.length()) {
            let parameter: WirValue = program.arena.values[wir_id_index(UInt32(function.parameters[param_index]))];
            if (!x86_is_i32_integer(program, parameter.type_id)) {
                return [];
            }

            offset = x86_align_frame_offset(offset + 4, 4);
            slots.append(X86StackSlot(value=function.parameters[param_index], offset=offset, size=4));
            param_index += 1;
        }
    }

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

func x86_spill_locations(slots: Vector(X86StackSlot), scratch: Vector(Int), count: Int) -> Vector(Int) {
    let offsets: Vector(Int) = [];
    let offset: Int = 0;

    if (slots.length() != 0) {
        offset = slots[slots.length() - 1].offset;
    }

    if (scratch.length() != 0 && 0 - scratch[scratch.length() - 1] > offset) {
        offset = 0 - scratch[scratch.length() - 1];
    }

    let i = 0;
    while (i < count) {
        offset = x86_align_frame_offset(offset + 4, 4);
        offsets.append(0 - offset);
        i++;
    }

    return offsets;
}

func x86_stack_frame_size(slots: Vector(X86StackSlot), scratch: Vector(Int), spills: Vector(Int)) -> Int {
    let size: Int = 0;
    if (slots.length() != 0) {
        size = slots[slots.length() - 1].offset;
    }

    if (scratch.length() != 0 && 0 - scratch[scratch.length() - 1] > size) {
        size = 0 - scratch[scratch.length() - 1];
    }
    if (spills.length() != 0 && 0 - spills[spills.length() - 1] > size) {
        size = 0 - spills[spills.length() - 1];
    }
    return x86_align_frame_offset(size, 16);
}

func x86_func_has_call(program: WirModule, function: WirFunction) -> Bool {
    let block_index = 0;
    while (block_index < function.blocks.length()) {
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(function.blocks[block_index]))];
        let instruction_index = 0;
        while (instruction_index < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[instruction_index]))];
            if (instruction.opcode == WirOpcode.Call) {
                return true;
            }

            instruction_index++;
        }
        block_index++;
    }
    return false;
}

func x86_function_call_frame(program: WirModule, function: WirFunction) -> Int {
    let frame_size: Int = 0;
    let block_index: Int = 0;
    while (block_index < function.blocks.length()) {
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(function.blocks[block_index]))];

        let instruction_index: Int = 0;
        while (instruction_index < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[instruction_index]))];
            if (instruction.opcode == WirOpcode.Call && instruction.call_type != NO_WIR_TYPE) {
                let signature: WirType = program.arena.types[wir_id_index(UInt32(instruction.call_type))];
                if (signature.kind == WirTypeKind.Function) {
                    let required: Int = x86_win64_call_frame(signature.parameters.length());
                    if (required > frame_size) {
                        frame_size = required;
                    }
                }
            }

            instruction_index += 1;
        }

        block_index += 1;
    }

    return frame_size;
}

func x86_home_parameters(program: WirModule, function: WirFunction, slots: Vector(X86StackSlot), ref output: X86CodeBuffer) -> Bool {
    let parameter_index: Int = 0;
    while (parameter_index < function.parameters.length()) {
        let offset: Int = x86_stack_offset(slots, function.parameters[parameter_index]);
        if (offset == 0) {
            return false;
        }

        if (parameter_index < 4) {
            let incoming: X86Register = x86_win64_argument_register(parameter_index, false);
            if (incoming == X86Register.None) {
                return false;
            }

            x86_store_register32_rbp_disp32(ref output, incoming, offset);
        } else {
            let incoming_offset: Int = x86_win64_stack_param_offset(parameter_index);
            if (incoming_offset < 0) {
                return false;
            }

            x86_load_eax_rbp_disp32(ref output, incoming_offset);
            x86_store_eax_rbp_disp32(ref output, offset);

        }
        parameter_index += 1;
    }
    return true;
}

func x86_save_live_registers(program: WirModule, slots: Vector(X86StackSlot), state: X86BlockState, ref output: X86CodeBuffer) -> String {
    let i: Int = 0;
    while (i < state.registers.bindings.length()) {
        let binding: X86RegisterBinding = state.registers.bindings[i];
        if (binding.value != NO_WIR_VALUE && x86_next_use(state.registers.uses, binding.value, state.position) != X86_NO_NEXT_USE) {
            if (x86_rematerializable(program, binding.value) || x86_stack_offset(slots, binding.value) != 0) {
                x86_clear_register(state.registers, binding.register);
            } else {
                let offset: Int = x86_claim_spill(state.spills, binding.value);
                if (offset == 0) { return "x86_64 spill storage is exhausted before a call"; }
                x86_store_register32_rbp_disp32(ref output, binding.register, offset);
                x86_clear_register(state.registers, binding.register);
            }
        }
        i += 1;
    }

    return "";
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
        return x86_lower_parameter_to_eax(program, function, value_id, slots, ref output);
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

func x86_prepare_register(program: WirModule, state: X86BlockState, choice: X86RegisterChoice, ref output: X86CodeBuffer) -> String {
    if (choice.register == X86Register.None) {
        return "no x86_64 register is available for this value";
    }

    if (choice.evicted == NO_WIR_VALUE) {
        return "";
    }

    let next_use: Int = x86_next_use(state.registers.uses, choice.evicted, state.position);
    if (next_use == X86_NO_NEXT_USE || x86_rematerializable(program, choice.evicted)) {
        x86_clear_register(state.registers, choice.register);
        return "";
    }

    if (x86_spill_offset(state.spills, choice.evicted) != 0) {
        x86_clear_register(state.registers, choice.register);
        return "";
    }

    let offset: Int = x86_claim_spill(state.spills, choice.evicted);
    if (offset == 0) {
        return "x86_64 spill storage is exhausted";
    }

    x86_store_register32_rbp_disp32(ref output, choice.register, offset);
    x86_clear_register(state.registers, choice.register);

    return "";
}

func x86_materialize_register_except(program: WirModule, function: WirFunction, value_id: WirValueID, slots: Vector(X86StackSlot), state: X86BlockState, avoid: X86Register, ref output: X86CodeBuffer) -> X86RegisterResult {
    let allocated: X86Register = x86_register_for(state.registers, value_id);
    if (allocated != X86Register.None) {
        return X86RegisterResult(register=allocated, message="");
    }

    let choice: X86RegisterChoice = x86_choose_register_except(program, state.registers, state.position, avoid);
    let prepare_error: String = x86_prepare_register(program, state, choice, ref output);
    if (prepare_error.length() != 0) {
        return X86RegisterResult(register=X86Register.None, message=prepare_error);
    }

    let value: WirValue = program.arena.values[wir_id_index(UInt32(value_id))];
    let spill: Int = x86_spill_offset(state.spills, value_id);
    if (spill != 0) {

        x86_load_register32_rbp_disp32(ref output, choice.register, spill);

    } else if (value.kind == WirValueKind.Integer) {
        if (!x86_is_i32_integer(program, value.type_id)) {
            return X86RegisterResult(register=X86Register.None, message="the initial x86_64 allocator supports 32-bit integer values");
        }

        x86_mov_register_imm32(ref output, choice.register, UInt32(value.integer));

    } else if (value.kind == WirValueKind.FunctionParameter) {
        let saved_offset: Int = x86_stack_offset(slots, value_id);
        if (saved_offset != 0) {
            x86_load_register32_rbp_disp32(ref output, choice.register, saved_offset);
            x86_bind_register(state.registers, choice.register, value_id);

            return X86RegisterResult(register=choice.register, message="");
        }
        let index: Int = x86_parameter_index(function, value_id);
        if (!x86_is_i32_integer(program, value.type_id)) {
            return X86RegisterResult(register=X86Register.None, message="the initial x86_64 allocator cannot load this function parameter");
        }
        if (index < 4) {
            let incoming: X86Register = x86_win64_argument_register(index, false);
            if (incoming == X86Register.None) {
                return X86RegisterResult(register=X86Register.None, message="the x86_64 ABI has no register for this function parameter");
            }

            x86_mov_register32(ref output, choice.register, incoming);

        } else {
            let incoming_offset: Int = x86_win64_stack_param_offset(index);
            if (incoming_offset < 0) {
                return X86RegisterResult(register=X86Register.None, message="the x86_64 ABI has no stack location for this function parameter");
            }

            x86_load_register32_rbp_disp32(ref output, choice.register, incoming_offset);

        }
    } else if (value.kind == WirValueKind.BlockParameter) {
        let offset: Int = x86_stack_offset(slots, value_id);
        if (offset == 0) {
            return X86RegisterResult(register=X86Register.None, message="block parameter has no assigned stack location");
        }

        x86_load_register32_rbp_disp32(ref output, choice.register, offset);

    } else {
        return X86RegisterResult(register=X86Register.None, message="the x86_64 allocator cannot restore this value");
    }

    x86_bind_register(state.registers, choice.register, value_id);
    return X86RegisterResult(register=choice.register, message="");
}

func x86_materialize_register(program: WirModule, function: WirFunction, value_id: WirValueID, slots: Vector(X86StackSlot), state: X86BlockState, ref output: X86CodeBuffer) -> X86RegisterResult {
    return x86_materialize_register_except(program, function, value_id, slots, state, X86Register.None, ref output);
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

func x86_function_code_offset(codes: Vector(X86FunctionCode), function: WirFuncID) -> Int {
    let i: Int = 0;
    while (i < codes.length()) {
        if (codes[i].function == function) { return codes[i].offset; }
        i += 1;
    }

    return -1;
}

func x86_patch_calls(program: WirModule, ref output: X86CodeBuffer, codes: Vector(X86FunctionCode)) -> Bool {
    let code_index: Int = 0;
    while (code_index < codes.length()) {
        let code: X86FunctionCode = codes[code_index];

        let call_index: Int = 0;
        while (call_index < code.calls.length()) {
            let call: X86CallFixup = code.calls[call_index];
            let target_index: Int = wir_id_index(UInt32(call.target));
            if (target_index < 0 || target_index >= program.arena.functions.length()) {
                return false;
            }
            if (program.arena.functions[target_index].linkage == WirLinkage.External) {
                call_index += 1;
                continue;
            }
            let target_offset: Int = x86_function_code_offset(codes, call.target);
            if (target_offset < 0) {
                return false;
            }

            let patch_offset: Int = code.offset + call.offset;
            let displacement: Int = target_offset - (patch_offset + 4);
            if (displacement < -2147483648 || displacement > 2147483647) {
                return false;
            }

            if (!x86_patch_i32(ref output, patch_offset, displacement)) {
                return false;
            }

            call_index++;
        }

        code_index++;
    }

    return true;
}

func x86_instruction_error(state: X86BlockState, message: String) -> X86BlockState {
    state.message = message;
    return state;
}

func x86_emit_edge_moves(program: WirModule, function: WirFunction, 
                        edge: WirEdge, slots: Vector(X86StackSlot), 
                        scratch: Vector(Int), state: X86BlockState, 
                        ref output: X86CodeBuffer) -> String {

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
        let source: X86RegisterResult = x86_materialize_register(
            program, 
            function, 
            edge.arguments[i], 
            slots, 
            state, 
            ref output
        );

        if (source.message.length() != 0) {
            return source.message;
        }

        x86_store_register32_rbp_disp32(ref output, source.register, scratch[i]);

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
        let stored: X86RegisterResult = x86_materialize_register(program, function, instruction.operands[0], slots, state, ref output);
        if (stored.message.length() != 0) {
            return x86_instruction_error(state, stored.message);
        }

        x86_store_register32_rbp_disp32(ref output, stored.register, offset);
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

        let choice: X86RegisterChoice = x86_choose_register(program, state.registers, state.position);
        let prepare_error: String = x86_prepare_register(program, state, choice, ref output);
        if (prepare_error.length() != 0) {
            return x86_instruction_error(state, prepare_error);
        }

        x86_load_register32_rbp_disp32(ref output, choice.register, offset);
        x86_bind_register(state.registers, choice.register, instruction.result);
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
        let right_id: WirValueID = instruction.operands[1];
        let right: WirValue = program.arena.values[wir_id_index(UInt32(right_id))];
        let left: X86RegisterResult = x86_materialize_register(program, function, left_id, slots, state, ref output);
        if (left.message.length() != 0) {
            return x86_instruction_error(state, left.message);
        }

        let right_register: X86Register = X86Register.None;
        if (right.kind != WirValueKind.Integer) {
            let loaded_right: X86RegisterResult = x86_materialize_register_except(program, function, right_id, slots, state, left.register, ref output);
            if (loaded_right.message.length() != 0) {
                return x86_instruction_error(state, loaded_right.message);
            }

            right_register = loaded_right.register;
        }

        let destination: X86Register = left.register;
        if (x86_next_use(state.registers.uses, left_id, state.position) != X86_NO_NEXT_USE) {
            let reuse_right: Bool = instruction.opcode != WirOpcode.Subtract && 
                                    right_register != X86Register.None &&
                                    x86_next_use(state.registers.uses, right_id, state.position) == X86_NO_NEXT_USE;
            if reuse_right {
                destination = right_register;
            } else {
                let choice: X86RegisterChoice = x86_choose_register_avoiding(program, state.registers, state.position, left.register, right_register);
                let prepare_error: String = x86_prepare_register(program, state, choice, ref output);
                if (prepare_error.length() != 0) {
                    return x86_instruction_error(state, prepare_error);
                }

                destination = choice.register;
                x86_mov_register32(ref output, destination, left.register);
            }
        }

        if (right.kind == WirValueKind.Integer) {
            if (instruction.opcode == WirOpcode.Add) {
                x86_add_register_imm32(ref output, destination, UInt32(right.integer));
            } else if (instruction.opcode == WirOpcode.Subtract) {
                x86_sub_register_imm32(ref output, destination, UInt32(right.integer));
            } else {
                x86_imul_register_imm32(ref output, destination, UInt32(right.integer));
            }
        } else {
            let source: X86Register = right_register;
            if (destination == right_register) {
                source = left.register;
            }

            if (instruction.opcode == WirOpcode.Add) {
                x86_add_register32(ref output, destination, source);
            } else if (instruction.opcode == WirOpcode.Subtract) {
                x86_sub_register32(ref output, destination, source);
            } else {
                x86_imul_register32(ref output, destination, source);
            }
        }

        x86_bind_register(state.registers, destination, instruction.result);
        state.accumulator = instruction.result;
        return state;
    }

    let comparison: X86Opcode = x86_comparison_opcode(instruction.opcode);
    if (comparison != X86Opcode.Invalid) {
        if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE || instruction.type_id != program.bool_type) {
            return x86_instruction_error(state, "comparison instruction has an invalid result or operand count");
        }
        let right_id: WirValueID = instruction.operands[1];
        let right: WirValue = program.arena.values[wir_id_index(UInt32(right_id))];
        let left: X86RegisterResult = x86_materialize_register(program, function, instruction.operands[0], slots, state, ref output);
        if (left.message.length() != 0) {
            return x86_instruction_error(state, left.message);
        }
        if (right.kind == WirValueKind.Integer) {
            x86_cmp_register_imm32(ref output, left.register, UInt32(right.integer));
        } else {
            let loaded_right: X86RegisterResult = x86_materialize_register_except(program, function, right_id, slots, state, left.register, ref output);
            if (loaded_right.message.length() != 0) { return x86_instruction_error(state, loaded_right.message); }
            x86_cmp_register32(ref output, left.register, loaded_right.register);
        }

        state.accumulator = instruction.operands[0];
        state.flags_value = instruction.result;
        state.flags_opcode = comparison;
        return state;
    }

    if (instruction.opcode == WirOpcode.Call) {
        if (instruction.operands.length() == 0 || instruction.call_type == NO_WIR_TYPE || instruction.result != NO_WIR_VALUE && !x86_is_i32_integer(program, instruction.type_id)) {
            return x86_instruction_error(state, "the initial x86_64 call lowering requires a direct 32-bit call result");
        }

        let callee: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
        if (callee.kind != WirValueKind.Function) {
            return x86_instruction_error(state, "the initial x86_64 call lowering requires a direct function value");
        }

        let signature: WirType = program.arena.types[wir_id_index(UInt32(instruction.call_type))];
        if (signature.kind != WirTypeKind.Function || signature.variadic || instruction.operands.length() - 1 != signature.parameters.length()) {
            return x86_instruction_error(state, "the initial x86_64 call lowering requires a fixed-arity function signature");
        }

        let save_error: String = x86_save_live_registers(program, slots, state, ref output);
        if (save_error.length() != 0) {
            return x86_instruction_error(state, save_error);
        }

        let argument_index: Int = 0;
        while (argument_index < signature.parameters.length()) {
            if (!x86_is_i32_integer(program, signature.parameters[argument_index])) {
                return x86_instruction_error(state, "the initial x86_64 call lowering supports 32-bit integer arguments");
            }

            let argument: X86RegisterResult = x86_materialize_register(program, function, instruction.operands[argument_index + 1], slots, state, ref output);
            if (argument.message.length() != 0) {
                return x86_instruction_error(state, argument.message);
            }

            if (argument_index < 4) {
                let destination: X86Register = x86_win64_argument_register(argument_index, false);
                if (destination == X86Register.None) {
                    return x86_instruction_error(state, "the x86_64 ABI has no register for this argument");
                }

                if (argument.register != destination) {
                    x86_mov_register32(ref output, destination, argument.register);
                }
            } else {
                let offset: Int = x86_win64_stack_arg_offset(argument_index);
                if (offset < 0) {
                    return x86_instruction_error(state, "the x86_64 ABI has no stack location for this argument");
                }
                
                x86_store_register32_base_disp32(ref output, argument.register, X86Register.RSP, offset);
            }
            argument_index += 1;
        }

        let target_function: WirFuncID = WirFuncID(callee.owner);
        calls.append(X86CallFixup(offset=x86_call_rel32(ref output), target=target_function));

        if (instruction.result != NO_WIR_VALUE) {
            x86_bind_register(state.registers, X86Register.RAX, instruction.result);
        }

        state.accumulator = instruction.result;
        return state;
    }

    if (instruction.opcode == WirOpcode.Jump) {
        if (instruction.operands.length() != 0 || instruction.edges.length() != 1) {
            return x86_instruction_error(state, "jump instruction has an unsupported edge shape");
        }

        let move_error: String = x86_emit_edge_moves(program, function, instruction.edges[0], slots, scratch, state, ref output);
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

            let move_error: String = x86_emit_edge_moves(program, function, instruction.edges[edge], slots, scratch, state, ref output);
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

        let false_move_error: String = x86_emit_edge_moves(program, function, instruction.edges[1], slots, scratch, state, ref output);
        if (false_move_error.length() != 0) {
            return x86_instruction_error(state, false_move_error);
        }

        fixups.append(X86BranchFixup(offset=x86_jump_rel32(ref output), target=instruction.edges[1].target));

        let true_offset: Int = output.bytes.length();
        if (!x86_patch_i32(ref output, true_patch, true_offset - (true_patch + 4))) {
            return x86_instruction_error(state, "the x86_64 lowering could not resolve the true edge transfer");
        }
        let true_move_error: String = x86_emit_edge_moves(program, function, instruction.edges[0], slots, scratch, state, ref output);
        if (true_move_error.length() != 0) {
            return x86_instruction_error(state, true_move_error);
        }

        fixups.append(X86BranchFixup(offset=x86_jump_rel32(ref output), target=instruction.edges[0].target));
        return state;
    }

    if (instruction.opcode == WirOpcode.Return) {
        if (instruction.operands.length() == 1) {
            let returned: X86RegisterResult = x86_materialize_register(program, function, instruction.operands[0], slots, state, ref output);
            if (returned.message.length() == 0) {
                if (returned.register != X86Register.RAX) {
                    x86_mov_eax_register32(ref output, returned.register);
                }
                if (frame_size > 0) {
                    x86_frame_leave(ref output);
                }

                x86_return(ref output);
                return state;
            }
        }
        if (instruction.operands.length() == 0) {
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

    let home_parameters: Bool = x86_function_has_call(program, function);
    let slots: Vector(X86StackSlot) = x86_collect_stack_slots(program, function, order, home_parameters);
    if home_parameters {
        located_values += function.parameters.length();
    }
    if (slots.length() != located_values) {
        return x86_lowering_error("the x86_64 lowering could not lay out a stack slot");
    }

    let scratch: Vector(Int) = x86_edge_scratch(slots, x86_edge_scratch_count(program, order));
    let uses: X86UseTable = x86_collect_uses(program, order);
    let register_plan: X86RegisterPlan = x86_register_plan(uses);

    let spill_count: Int = x86_spill_capacity(program, order, uses, register_plan.bindings.length());
    let spill_locations: Vector(Int) = x86_spill_locations(slots, scratch, spill_count);
    let spill_plan: X86SpillPlan = x86_new_spill_plan(spill_locations);

    let frame_size: Int = x86_stack_frame_size(slots, scratch, spill_locations);
    let call_frame: Int = x86_function_call_frame(program, function);
    if (call_frame > 0) {
        frame_size = x86_align_frame_offset(frame_size + call_frame, 16);
    }

    let output: X86CodeBuffer = x86_new_code_buffer();
    let offsets: Vector(X86BlockOffset) = [];
    let fixups: Vector(X86BranchFixup) = [];
    let calls: Vector(X86CallFixup) = [];
    let position: Int = 0;
    if (frame_size > 0) {
        x86_frame_enter(ref output, frame_size);
    }
    if (home_parameters && !x86_home_parameters(program, function, slots, ref output)) {
        return x86_lowering_error("the x86_64 lowering could not save function parameters");
    }

    block_index = 0;
    while (block_index < order.length()) {
        let block_id: WirBlockID = order[block_index];
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(block_id))];
        offsets.append(X86BlockOffset(block=block_id, offset=output.bytes.length()));
        x86_reset_registers(register_plan);
        x86_reset_spills(spill_plan);

        let state: X86BlockState = X86BlockState(accumulator=NO_WIR_VALUE, flags_value=NO_WIR_VALUE, flags_opcode=X86Opcode.Invalid, registers=register_plan, spills=spill_plan, position=position, message="");
        let instruction_index: Int = 0;
        while (instruction_index < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[instruction_index]))];
            state = x86_lower_instruction(program, function, instruction, slots, scratch, frame_size, state, ref output, ref fixups, ref calls);

            if (state.message.length() != 0) {
                return x86_lowering_error(state.message);
            }

            x86_consume_instruction(state.registers.uses, instruction, state.position);
            x86_release_dead_registers(state.registers, state.position);
            x86_release_dead_spills(state.spills, state.registers.uses, state.position);

            state.position += 1;
            instruction_index += 1;
        }

        position = state.position;
        block_index += 1;
    }

    if (!x86_patch_branches(ref output, offsets, fixups)) {
        return x86_lowering_error("the x86_64 lowering could not resolve a branch target");
    }

    return X86LoweringResult(bytes=output.bytes, errors=[], calls=calls);
}

func x86_lower_module(program: WirModule) -> X86ModuleResult {
    let codes: Vector(X86FunctionCode) = [];
    let relocations: Vector(X86Relocation) = [];
    let symbols: Vector(X86Symbol) = [];
    let output: X86CodeBuffer = x86_new_code_buffer();
    let function_index = 0;
    while (function_index < program.arena.functions.length()) {
        let function: WirFunction = program.arena.functions[function_index];
        if (function.linkage != WirLinkage.External) {
            let function_id: WirFuncID = WirFuncID(UInt32(function_index + 1));
            let lowered: X86LoweringResult = x86_lower_function(program, function_id);
            if (lowered.errors.length() != 0) {
                return x86_module_error(lowered.errors[0]);
            }

            let offset: Int = output.bytes.length();
            let i: Int = 0;
            while (i < lowered.bytes.length()) {
                output.bytes.append(lowered.bytes[i]);
                i++;
            }

            codes.append(X86FunctionCode(function=function_id, offset=offset, bytes=lowered.bytes, calls=lowered.calls));
            symbols.append(X86Symbol(name=function.name, section=".text", offset=UInt32(offset), external=function.linkage == WirLinkage.Exported));
        }

        function_index++;
    }

    let code_index = 0;
    while (code_index < codes.length()) {
        let code: X86FunctionCode = codes[code_index];
        let call_index = 0;
        while (call_index < code.calls.length()) {
            let call: X86CallFixup = code.calls[call_index];
            let target_index: Int = wir_id_index(UInt32(call.target));
            if (target_index < 0 || target_index >= program.arena.functions.length()) {
                return x86_module_error("the x86_64 lowering could not resolve a call target");
            }

            let target: WirFunction = program.arena.functions[target_index];
            if (target.linkage == WirLinkage.External) {
                relocations.append(X86Relocation(section=".text", offset=UInt32(code.offset + call.offset), kind=X86RelocationKind.Rel32, symbol=target.name, addend=-4L));

                let patch_offset: Int = code.offset + call.offset;
                output.bytes[patch_offset] = Byte(252);
                output.bytes[patch_offset + 1] = Byte(255);
                output.bytes[patch_offset + 2] = Byte(255);
                output.bytes[patch_offset + 3] = Byte(255);
            }
            call_index++;
        }
        code_index++;
    }

    function_index = 0;
    while (function_index < program.arena.functions.length()) {
        let function: WirFunction = program.arena.functions[function_index];
        if (function.linkage == WirLinkage.External) {
            let duplicate = false;
            let symbol_index = 0;
            while (symbol_index < symbols.length()) {
                if (symbols[symbol_index].name == function.name) {
                    duplicate = true;
                }

                symbol_index++;
            }

            if (!duplicate) {
                symbols.append(X86Symbol(name=function.name, section="", offset=0U, external=true));
            }
        }

        function_index++;
    }

    if (!x86_patch_calls(program, ref output, codes)) {
        return x86_module_error("the x86_64 lowering could not resolve a direct call target");
    }

    return X86ModuleResult(bytes=output.bytes, errors=[], relocations=relocations, symbols=symbols);
}
