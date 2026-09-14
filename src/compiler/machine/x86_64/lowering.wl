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

func x86_collect_stack_slots(program: WirModule, block: WirBlock) -> Vector(X86StackSlot) {
    let slots: Vector(X86StackSlot) = [];
    let offset = 0;
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

func x86_stack_frame_size(slots: Vector(X86StackSlot)) -> Int {
    if (slots.length() == 0) {
        return 0;
    }

    return x86_align_frame_offset(slots[slots.length() - 1].offset, 16);
}

func x86_lower_value_to_eax(program: WirModule, function: WirFunction, value_id: WirValueID, accumulator: WirValueID, ref output: X86CodeBuffer) -> Bool {
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

    return false;
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
    if (function.blocks.length() != 1) {
        return x86_lowering_error("the initial x86_64 lowering supports one basic block");
    }

    let block_index: Int = wir_id_index(UInt32(function.blocks[0]));
    if (block_index < 0 || block_index >= program.arena.blocks.length()) {
        return x86_lowering_error("function refers to an unknown basic block");
    }
    let block: WirBlock = program.arena.blocks[block_index];
    if (block.function != function_id) {
        return x86_lowering_error("function refers to a basic block owned by another function");
    }
    if (block.instructions.length() == 0) {
        return x86_lowering_error("the initial x86_64 lowering requires a non-empty basic block");
    }

    let output: X86CodeBuffer = x86_new_code_buffer();
    let slots: Vector(X86StackSlot) = x86_collect_stack_slots(program, block);
    let stack_allocations: Int = 0;
    let slot_scan: Int = 0;
    while (slot_scan < block.instructions.length()) {
        let scan_instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[slot_scan]))];
        if (scan_instruction.opcode == WirOpcode.StackAlloc) {
            stack_allocations += 1;
        }

        slot_scan += 1;
    }
    if (slots.length() != stack_allocations) {
        return x86_lowering_error("the x86_64 lowering could not lay out a stack slot");
    }

    let frame_size: Int = x86_stack_frame_size(slots);
    if (frame_size > 0) {
        x86_frame_enter(ref output, frame_size);
    }

    let accumulator: WirValueID = NO_WIR_VALUE;
    let i = 0;
    while (i < block.instructions.length()) {
        let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[i]))];
        if (instruction.opcode == WirOpcode.StackAlloc) {
            accumulator = NO_WIR_VALUE;
        } else if (instruction.opcode == WirOpcode.Store) {
            if (instruction.operands.length() != 2) { return x86_lowering_error("store instruction has the wrong operand count"); }
            let offset: Int = x86_stack_offset(slots, instruction.operands[1]);
            if (offset == 0) {
                return x86_lowering_error("store does not refer to a known stack slot");
            }

            if (!x86_is_i32_integer(program, program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id)) {
                return x86_lowering_error("the initial x86_64 lowering supports 32-bit integer stores");
            }

            if (!x86_lower_value_to_eax(program, function, instruction.operands[0], accumulator, ref output)) {
                return x86_lowering_error("the initial x86_64 lowering cannot store this value");
            }

            x86_store_eax_rbp_disp32(ref output, offset);
            accumulator = instruction.operands[0];
        } else if (instruction.opcode == WirOpcode.Load) {
            if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
                return x86_lowering_error("load instruction has the wrong operand count");
            }

            let offset: Int = x86_stack_offset(slots, instruction.operands[0]);
            if (offset == 0) {
                return x86_lowering_error("load does not refer to a known stack slot");
            }

            if (!x86_is_i32_integer(program, instruction.type_id)) {
                return x86_lowering_error("the initial x86_64 lowering supports 32-bit integer loads");
            }

            x86_load_eax_rbp_disp32(ref output, offset);
            accumulator = instruction.result;

        } else if (instruction.opcode == WirOpcode.Add || instruction.opcode == WirOpcode.Subtract || instruction.opcode == WirOpcode.Multiply) {
            if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
                return x86_lowering_error("arithmetic instruction has the wrong operand count");
            }

            let result_type: WirType = program.arena.types[wir_id_index(UInt32(instruction.type_id))];
            if ((result_type.kind != WirTypeKind.SignedInt && result_type.kind != WirTypeKind.UnsignedInt) || result_type.bits > 32) {
                return x86_lowering_error("the initial x86_64 lowering supports 32-bit integer arithmetic");
            }

            let left_id: WirValueID = instruction.operands[0];
            let right_id: WirValueID = instruction.operands[1];
            let left: WirValue = program.arena.values[wir_id_index(UInt32(left_id))];
            let right: WirValue = program.arena.values[wir_id_index(UInt32(right_id))];
            if (right.kind != WirValueKind.Integer) {
                return x86_lowering_error("the initial x86_64 lowering requires an integer arithmetic right operand");
            }
            if (left.kind == WirValueKind.Integer) {
                x86_mov_eax_imm32(ref output, UInt32(left.integer));
            } else if (left.kind == WirValueKind.FunctionParameter) {
                if (!x86_lower_parameter_to_eax(program, function, left_id, ref output)) {
                    return x86_lowering_error("the initial x86_64 lowering cannot pass this function parameter");
                }
            } else if (left_id != accumulator) {
                return x86_lowering_error("the initial x86_64 lowering cannot allocate this arithmetic operand");
            }

            if (instruction.opcode == WirOpcode.Add) {
                x86_add_eax_imm32(ref output, UInt32(right.integer));
            } else if (instruction.opcode == WirOpcode.Subtract) {
                x86_sub_eax_imm32(ref output, UInt32(right.integer));
            } else {
                x86_imul_eax_imm32(ref output, UInt32(right.integer));
            }

            accumulator = instruction.result;
        } else if (instruction.opcode == WirOpcode.Return) {
            if (instruction.operands.length() == 1) {
                let returned_id: WirValueID = instruction.operands[0];
                let returned: WirValue = program.arena.values[wir_id_index(UInt32(returned_id))];
                if (returned_id == accumulator) {
                    if (frame_size > 0) {
                        x86_frame_leave(ref output);
                    }

                    x86_return(ref output);
                } else if (returned.kind == WirValueKind.FunctionParameter) {
                    if (!x86_lower_parameter_to_eax(program, function, returned_id, ref output)) {
                        return x86_lowering_error("the initial x86_64 lowering cannot return this function parameter");
                    }

                    if (frame_size > 0) {
                        x86_frame_leave(ref output);
                    }

                    x86_return(ref output);
                } else if (!x86_lower_return(program, instruction, frame_size, ref output)) {
                    return x86_lowering_error("unsupported return operand in the initial x86_64 lowering");
                }
            } else if (!x86_lower_return(program, instruction, frame_size, ref output)) {
                return x86_lowering_error("unsupported return operand in the initial x86_64 lowering");
            }
        } else {
            return x86_lowering_error("unsupported instruction in the initial x86_64 lowering");
        }
        i++;
    }
    return X86LoweringResult(bytes=output.bytes, errors=[]);
}
