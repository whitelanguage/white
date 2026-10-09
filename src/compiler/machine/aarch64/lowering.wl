// src/compiler/machine/aarch64/lowering.wl
import * from "model.wl"
import * from "encoder.wl"
import a64_argument_register from "abi.wl"
import * from "../../wir/model.wl"


struct A64LoweringResult(
    bytes: Vector(Byte),
    errors: Vector(String),
    relocations: Vector(A64Relocation)
)

struct A64ModuleResult(
    errors: Vector(String),
    sections: Vector(A64Section),
    symbols: Vector(A64Symbol),
    relocations: Vector(A64Relocation)
)

struct A64ValueMap(registers: Vector(A64Register), next_register: Int)

struct A64BlockOffset(block: WirBlockID, offset: Int)

struct A64BranchFixup(
    offset: Int,
    target: WirBlockID,
    condition: A64Condition,
    conditional: Bool
)

struct A64StackSlot(value: WirValueID, offset: Int, size: Int)

struct A64StackLayout(
    storage: Vector(A64StackSlot),
    homes: Vector(A64StackSlot),
    frame_size: Int,
    message: String
)

func a64_lowering_error(message: String) -> A64LoweringResult {
    return A64LoweringResult(bytes=[], errors=[message], relocations=[]);
}

func a64_module_error(message: String) -> A64ModuleResult {
    return A64ModuleResult(errors=[message], sections=[], symbols=[], relocations=[]);
}

func a64_scalar_width(ref program: WirModule, type_id: WirTypeID) -> Int {
    let index: Int = wir_id_index(UInt32(type_id));
    if (index < 0 || index >= program.arena.types.length()) { return 0; }

    let type: WirType = program.arena.types[index];
    if (type.kind == WirTypeKind.BoolType) { return 32; }
    if (type.kind == WirTypeKind.Pointer || type.kind == WirTypeKind.Function) { return 64; }
    if (type.kind != WirTypeKind.SignedInt && type.kind != WirTypeKind.UnsignedInt) { return 0; }
    if (type.bits <= 0 || type.bits > 64) { return 0; }
    if (type.bits <= 32) { return 32; }

    return 64;
}

func a64_align(value: Int, alignment: Int) -> Int {
    if (alignment <= 1) { return value; }
    return ((value + alignment - 1) / alignment) * alignment;
}

func a64_stack_layout(ref program: WirModule, ref function: WirFunction) -> A64StackLayout {
    let storage: Vector(A64StackSlot) = [];
    let homes: Vector(A64StackSlot) = [];
    let size: Int = 0;
    let i: Int = 0;

    while (i < function.parameters.length()) {
        let param: WirValueID = function.parameters[i];
        let width: Int = a64_scalar_width(ref program, program.arena.values[wir_id_index(UInt32(param))].type_id);
        if (width == 0) {
            return A64StackLayout(storage=[], homes=[], frame_size=0, message="initial AArch64 parameter homes only support scalar values");
        }

        let bytes: Int = width / 8;
        size = a64_align(size, bytes);
        homes.append(A64StackSlot(value=param, offset=size, size=bytes));
        size += bytes;
        i++;
    }

    i = 0;
    while (i < function.blocks.length()) {
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(function.blocks[i]))];
        let j: Int = 0;

        let param_index: Int = 0;
        while (param_index < block.parameters.length()) {
            let param: WirValueID = block.parameters[param_index];
            let width: Int = a64_scalar_width(ref program, program.arena.values[wir_id_index(UInt32(param))].type_id);
            if (width == 0) {
                return A64StackLayout(storage=[], homes=[], frame_size=0, message="initial AArch64 block parameter homes only support scalar values");
            }

            let bytes: Int = width / 8;
            size = a64_align(size, bytes);
            homes.append(A64StackSlot(value=param, offset=size, size=bytes));
            size += bytes;
            param_index++;
        }

        while (j < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[j]))];
            if (instruction.opcode == WirOpcode.StackAlloc) {
                let pointer: WirType = program.arena.types[wir_id_index(UInt32(instruction.type_id))];
                let width: Int = 0;
                if (pointer.kind == WirTypeKind.Pointer) { width = a64_scalar_width(ref program, pointer.element); }
                if (instruction.result == NO_WIR_VALUE || width == 0) {
                    return A64StackLayout(storage=[], homes=[], frame_size=0, message="initial AArch64 stack slots only support scalar values");
                }

                let bytes: Int = width / 8;
                size = a64_align(size, bytes);
                storage.append(A64StackSlot(value=instruction.result, offset=size, size=bytes));
                size += bytes;
            } else if (instruction.result != NO_WIR_VALUE) {
                let width: Int = a64_scalar_width(ref program, instruction.type_id);
                if (width != 0) {
                    let bytes: Int = width / 8;
                    size = a64_align(size, bytes);
                    homes.append(A64StackSlot(value=instruction.result, offset=size, size=bytes));
                    size += bytes;
                }
            }
            j++;
        }
        i++;
    }

    let frame_size: Int = a64_align(size, 16);
    if (frame_size > 4095) {
        return A64StackLayout(storage=[], homes=[], frame_size=0, message="initial AArch64 stack frame exceeds the immediate range");
    }

    return A64StackLayout(storage=storage, homes=homes, frame_size=frame_size, message="");
}

func a64_find_stack_slot(slots: Vector(A64StackSlot), value: WirValueID) -> A64StackSlot {
    let i: Int = 0;
    while (i < slots.length()) {
        if (slots[i].value == value) { return slots[i]; }
        i++;
    }

    return A64StackSlot(value=NO_WIR_VALUE, offset=0, size=0);
}

func a64_work_register(index: Int) -> A64Register {
// X9-X15 are caller-saved temporaries and do not overlap ABI argument registers.
    if (index == 0) { return A64Register.X9; }
    if (index == 1) { return A64Register.X10; }
    if (index == 2) { return A64Register.X11; }
    if (index == 3) { return A64Register.X12; }
    if (index == 4) { return A64Register.X13; }
    if (index == 5) { return A64Register.X14; }
    if (index == 6) { return A64Register.X15; }

    return A64Register.None;
}

func a64_new_value_map(value_count: Int) -> A64ValueMap {
    let registers: Vector(A64Register) = [];
    let i: Int = 0;

    while (i < value_count) {
        registers.append(A64Register.None);
        i++;
    }

    return A64ValueMap(registers=registers, next_register=0);
}

func a64_alloc_register(ref values: A64ValueMap) -> A64Register {
    let register: A64Register = a64_work_register(values.next_register % 7);
    values.next_register++;

    return register;
}

func a64_bind_value(ref values: A64ValueMap, value_id: WirValueID, register: A64Register) -> Bool {
    let index: Int = wir_id_index(UInt32(value_id));
    if (index < 0 || index >= values.registers.length()) { return false; }

    values.registers[index] = register;
    return true;
}

func a64_mapped_register(ref values: A64ValueMap, value_id: WirValueID) -> A64Register {
    let index: Int = wir_id_index(UInt32(value_id));
    if (index < 0 || index >= values.registers.length()) { return A64Register.None; }

    return values.registers[index];
}

func a64_materialize(
    ref program: WirModule,
    value_id: WirValueID,
    homes: Vector(A64StackSlot),
    ref values: A64ValueMap,
    ref output: A64CodeBuffer
) -> A64Register {
    let index: Int = wir_id_index(UInt32(value_id));
    if (index < 0 || index >= program.arena.values.length()) { return A64Register.None; }

    let value: WirValue = program.arena.values[index];
    let home: A64StackSlot = a64_find_stack_slot(homes, value_id);
    if (home.value != NO_WIR_VALUE) {
        let register: A64Register = a64_alloc_register(ref values);
        let width: Int = a64_scalar_width(ref program, value.type_id);
        if (register == A64Register.None || width == 0 || home.size != width / 8 ||
            !a64_load_unsigned(ref output, register, A64Register.SP, home.offset, width == 64)) {
            return A64Register.None;
        }

        return register;
    }

    if (value.kind != WirValueKind.Integer && value.kind != WirValueKind.BoolValue && value.kind != WirValueKind.Null) {
        return A64Register.None;
    }

    let width: Int = a64_scalar_width(ref program, value.type_id);
    if (width == 0) { return A64Register.None; }

    let register: A64Register = a64_alloc_register(ref values);
    if (register == A64Register.None) { return register; }

    let bits: UInt64 = UInt64(value.integer & UInt128(18446744073709551615UL));
    if (!a64_mov_immediate(ref output, register, bits, width == 64)) {
        return A64Register.None;
    }

    return register;
}

func a64_save_home(ref output: A64CodeBuffer, homes: Vector(A64StackSlot), value: WirValueID, register: A64Register, width: Int) -> Bool {
    let home: A64StackSlot = a64_find_stack_slot(homes, value);
    if (home.value == NO_WIR_VALUE || width == 0 || home.size != width / 8) { return false; }

    return a64_store_unsigned(ref output, register, A64Register.SP, home.offset, width == 64);
}

func a64_comparison_condition(opcode: WirOpcode) -> A64Condition {
    if (opcode == WirOpcode.Equal) { return A64Condition.Equal; }
    if (opcode == WirOpcode.NotEqual) { return A64Condition.NotEqual; }
    if (opcode == WirOpcode.SignedLess) { return A64Condition.SignedLess; }
    if (opcode == WirOpcode.SignedLessEqual) { return A64Condition.SignedLessOrEqual; }
    if (opcode == WirOpcode.SignedGreater) { return A64Condition.SignedGreater; }
    if (opcode == WirOpcode.SignedGreaterEqual) { return A64Condition.SignedGreaterOrEqual; }
    if (opcode == WirOpcode.UnsignedLess) { return A64Condition.CarryClear; }
    if (opcode == WirOpcode.UnsignedLessEqual) { return A64Condition.UnsignedLowerOrSame; }
    if (opcode == WirOpcode.UnsignedGreater) { return A64Condition.UnsignedHigher; }
    if (opcode == WirOpcode.UnsignedGreaterEqual) { return A64Condition.CarrySet; }

    return A64Condition.Never;
}

func a64_is_integer_comparison(opcode: WirOpcode) -> Bool {
    return opcode == WirOpcode.Equal || opcode == WirOpcode.NotEqual ||
           opcode == WirOpcode.SignedLess || opcode == WirOpcode.SignedLessEqual ||
           opcode == WirOpcode.SignedGreater || opcode == WirOpcode.SignedGreaterEqual ||
           opcode == WirOpcode.UnsignedLess || opcode == WirOpcode.UnsignedLessEqual ||
           opcode == WirOpcode.UnsignedGreater || opcode == WirOpcode.UnsignedGreaterEqual;
}

func a64_is_integer_binary(opcode: WirOpcode) -> Bool {
    return opcode == WirOpcode.Add || opcode == WirOpcode.Subtract || opcode == WirOpcode.Multiply ||
           opcode == WirOpcode.BitAnd || opcode == WirOpcode.BitOr || opcode == WirOpcode.BitXor ||
           opcode == WirOpcode.ShiftLeft || opcode == WirOpcode.SignedShiftRight || opcode == WirOpcode.UnsignedShiftRight;
}

func a64_emit_integer_binary(ref output: A64CodeBuffer, opcode: WirOpcode, destination: A64Register, left: A64Register, right: A64Register, wide: Bool) -> Bool {
    if (opcode == WirOpcode.Add) { return a64_add_register(ref output, destination, left, right, wide); }
    if (opcode == WirOpcode.Subtract) { return a64_sub_register(ref output, destination, left, right, wide); }
    if (opcode == WirOpcode.Multiply) { return a64_multiply_register(ref output, destination, left, right, wide); }
    if (opcode == WirOpcode.BitAnd) { return a64_logical_register(ref output, destination, left, right, 0, wide); }
    if (opcode == WirOpcode.BitOr) { return a64_logical_register(ref output, destination, left, right, 1, wide); }
    if (opcode == WirOpcode.BitXor) { return a64_logical_register(ref output, destination, left, right, 2, wide); }
    if (opcode == WirOpcode.ShiftLeft) { return a64_shift_register(ref output, destination, left, right, 0, wide); }
    if (opcode == WirOpcode.SignedShiftRight) { return a64_shift_register(ref output, destination, left, right, 1, wide); }
    if (opcode == WirOpcode.UnsignedShiftRight) { return a64_shift_register(ref output, destination, left, right, 2, wide); }

    return false;
}

func a64_block_offset(offsets: Vector(A64BlockOffset), block: WirBlockID) -> Int {
    let i: Int = 0;
    while (i < offsets.length()) {
        if (offsets[i].block == block) { return offsets[i].offset; }
        i++;
    }

    return -1;
}

func a64_patch_branches(ref output: A64CodeBuffer, offsets: Vector(A64BlockOffset), fixups: Vector(A64BranchFixup)) -> Bool {
    let i: Int = 0;

    while (i < fixups.length()) {
        let fixup: A64BranchFixup = fixups[i];
        let target: Int = a64_block_offset(offsets, fixup.target);
        if (target < 0 || !a64_patch_branch(ref output, fixup.offset, target, fixup.condition, fixup.conditional)) {
            return false;
        }
        i++;
    }

    return true;
}

func a64_write_edge(ref program: WirModule, edge: WirEdge, homes: Vector(A64StackSlot), ref values: A64ValueMap, ref output: A64CodeBuffer) -> Bool {
// Block arguments are copied through homes, this also handles swaps on loop edges.
    let block_index: Int = wir_id_index(UInt32(edge.target));
    if (block_index < 0 || block_index >= program.arena.blocks.length()) { return false; }

    let target: WirBlock = program.arena.blocks[block_index];
    if (target.parameters.length() != edge.arguments.length()) { return false; }

    let i: Int = 0;
    while (i < edge.arguments.length()) {
        let argument: WirValueID = edge.arguments[i];
        let parameter: WirValueID = target.parameters[i];
        let width: Int = a64_scalar_width(ref program, program.arena.values[wir_id_index(UInt32(parameter))].type_id);
        let source: A64Register = a64_materialize(ref program, argument, homes, ref values, ref output);
        if (source == A64Register.None || width == 0 || !a64_save_home(ref output, homes, parameter, source, width)) {
            return false;
        }
        i++;
    }

    return true;
}

func a64_lower_function(ref program: WirModule, function_id: WirFuncID) -> A64LoweringResult {
    if (program.target != "aarch64-unknown-linux-gnu" || program.pointer_bits != 64) {
        return a64_lowering_error("the AArch64 backend does not support this target");
    }

    let function_index: Int = wir_id_index(UInt32(function_id));
    if (function_index < 0 || function_index >= program.arena.functions.length()) {
        return a64_lowering_error("function id is outside the WIR arena");
    }

    let function: WirFunction = program.arena.functions[function_index];
    if (function.blocks.length() == 0 || function.entry != function.blocks[0]) {
        return a64_lowering_error("AArch64 lowering requires a valid entry block");
    }
    if (function.parameters.length() > 8) {
        return a64_lowering_error("initial AArch64 lowering supports at most eight integer parameters");
    }

    let output: A64CodeBuffer = a64_new_code_buffer();
    let values: A64ValueMap = a64_new_value_map(program.arena.values.length());
    let offsets: Vector(A64BlockOffset) = [];
    let fixups: Vector(A64BranchFixup) = [];
    let stack: A64StackLayout = a64_stack_layout(ref program, ref function);
    if (stack.message.length() != 0) { return a64_lowering_error(stack.message); }

    let has_call: Bool = false;
    let i: Int = 0;

    while (i < function.blocks.length()) {
        let scan_block: WirBlock = program.arena.blocks[wir_id_index(UInt32(function.blocks[i]))];
        let j: Int = 0;
        while (j < scan_block.instructions.length()) {
            let scan: WirInstruction = program.arena.instructions[wir_id_index(UInt32(scan_block.instructions[j]))];
            if (scan.opcode == WirOpcode.Call) { has_call = true; }
            j++;
        }
        i++;
    }
    let has_frame: Bool = has_call || stack.frame_size != 0;
    if (has_frame && !a64_enter_sized_frame(ref output, stack.frame_size)) {
        return a64_lowering_error("cannot encode the AArch64 stack frame");
    }

    i = 0;
    while (i < function.parameters.length()) {
        let parameter: WirValueID = function.parameters[i];
        let value: WirValue = program.arena.values[wir_id_index(UInt32(parameter))];
        let width: Int = a64_scalar_width(ref program, value.type_id);
        if (width == 0) {
            return a64_lowering_error("initial AArch64 lowering only supports scalar integer parameters");
        }
        if (!a64_save_home(ref output, stack.homes, parameter, a64_argument_register(i, false), width)) {
            return a64_lowering_error("cannot save an AArch64 argument register");
        }
        i++;
    }

    i = 0;
    while (i < function.blocks.length()) {
        let block_id: WirBlockID = function.blocks[i];
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(block_id))];
        offsets.append(A64BlockOffset(block=block_id, offset=output.bytes.length()));

        let instruction_index: Int = 0;
        while (instruction_index < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[instruction_index]))];

            if (instruction.opcode == WirOpcode.StackAlloc) {
                // stack slots were assigned before instruction selection
            } else if (instruction.opcode == WirOpcode.Load) {
                if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("load has an invalid WIR shape");
                }

                let slot: A64StackSlot = a64_find_stack_slot(stack.storage, instruction.operands[0]);
                let destination: A64Register = a64_alloc_register(ref values);
                let width: Int = a64_scalar_width(ref program, instruction.type_id);
                if (slot.value == NO_WIR_VALUE || destination == A64Register.None || width == 0 ||
                    !a64_load_unsigned(ref output, destination, A64Register.SP, slot.offset, width == 64) ||
                    !a64_save_home(ref output, stack.homes, instruction.result, destination, width)) {
                    return a64_lowering_error("cannot encode AArch64 scalar load");
                }
            } else if (instruction.opcode == WirOpcode.Store) {
                if (instruction.operands.length() != 2 || instruction.result != NO_WIR_VALUE) {
                    return a64_lowering_error("store has an invalid WIR shape");
                }

                let source: A64Register = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let slot: A64StackSlot = a64_find_stack_slot(stack.storage, instruction.operands[1]);
                let width: Int = a64_scalar_width(ref program, program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id);
                if (source == A64Register.None || slot.value == NO_WIR_VALUE || width == 0 || slot.size != width / 8 ||
                    !a64_store_unsigned(ref output, source, A64Register.SP, slot.offset, width == 64)) {
                    return a64_lowering_error("cannot encode AArch64 scalar store");
                }
            } else if (a64_is_integer_binary(instruction.opcode)) {
                if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("integer arithmetic has an invalid WIR shape");
                }

                let left: A64Register = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let right: A64Register = a64_materialize(ref program, instruction.operands[1], stack.homes, ref values, ref output);
                let destination: A64Register = a64_alloc_register(ref values);
                let width: Int = a64_scalar_width(ref program, instruction.type_id);
                if (left == A64Register.None || right == A64Register.None || destination == A64Register.None || width == 0) {
                    return a64_lowering_error("AArch64 integer arithmetic ran out of temporary registers");
                }

                let encoded: Bool = a64_emit_integer_binary(ref output, instruction.opcode, destination, left, right, width == 64);
                if (!encoded || !a64_save_home(ref output, stack.homes, instruction.result, destination, width)) {
                    return a64_lowering_error("cannot encode AArch64 integer arithmetic");
                }
            } else if (a64_is_integer_comparison(instruction.opcode)) {
                if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("integer comparison has an invalid WIR shape");
                }

                let left: A64Register = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let right: A64Register = a64_materialize(ref program, instruction.operands[1], stack.homes, ref values, ref output);
                let destination: A64Register = a64_alloc_register(ref values);
                let input_type: WirTypeID = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id;
                let width: Int = a64_scalar_width(ref program, input_type);
                let condition: A64Condition = a64_comparison_condition(instruction.opcode);

                if (left == A64Register.None || right == A64Register.None || destination == A64Register.None || width == 0 ||
                    condition == A64Condition.Never || !a64_compare_register(ref output, left, right, width == 64) ||
                    !a64_set_condition(ref output, destination, condition) ||
                    !a64_save_home(ref output, stack.homes, instruction.result, destination, 32)) {
                    return a64_lowering_error("cannot encode AArch64 integer comparison");
                }
            } else if (instruction.opcode == WirOpcode.Call) {
                if (instruction.operands.length() == 0 || instruction.operands.length() > 9 || instruction.call_type == NO_WIR_TYPE) {
                    return a64_lowering_error("initial AArch64 calls support a direct target and up to eight scalar arguments");
                }

                let callee: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
                if (callee.kind != WirValueKind.Function) {
                    return a64_lowering_error("initial AArch64 lowering only supports direct calls");
                }

                let callee_id: WirFuncID = WirFuncID(callee.owner);
                let callee_index: Int = wir_id_index(UInt32(callee_id));
                if (callee_index < 0 || callee_index >= program.arena.functions.length()) {
                    return a64_lowering_error("direct call target is outside the WIR function arena");
                }
                let callee_function: WirFunction = program.arena.functions[callee_index];

                let call_type: WirType = program.arena.types[wir_id_index(UInt32(instruction.call_type))];
                if (call_type.parameters.length() != instruction.operands.length() - 1) {
                    return a64_lowering_error("AArch64 call arguments do not match the WIR function type");
                }

                let argument_index: Int = 1;
                while (argument_index < instruction.operands.length()) {
                    let argument: WirValueID = instruction.operands[argument_index];
                    let width: Int = a64_scalar_width(ref program, program.arena.values[wir_id_index(UInt32(argument))].type_id);
                    let source: A64Register = a64_materialize(ref program, argument, stack.homes, ref values, ref output);
                    let destination: A64Register = a64_argument_register(argument_index - 1, false);
                    if (width == 0 || source == A64Register.None || destination == A64Register.None ||
                        (source != destination && !a64_mov_register(ref output, destination, source, width == 64))) {
                        return a64_lowering_error("cannot assign an AArch64 call argument");
                    }
                    argument_index++;
                }

                if (!a64_branch_symbol(ref output, callee_function.name, true)) {
                    return a64_lowering_error("cannot encode an AArch64 direct call");
                }

                let result_width: Int = a64_scalar_width(ref program, instruction.type_id);
                if (instruction.result != NO_WIR_VALUE &&
                    (result_width == 0 || !a64_save_home(ref output, stack.homes, instruction.result, A64Register.X0, result_width))) {
                    return a64_lowering_error("cannot bind the AArch64 call result");
                }
            } else if (instruction.opcode == WirOpcode.Jump) {
                if (instruction.operands.length() != 0 || instruction.edges.length() != 1 ||
                    !a64_write_edge(ref program, instruction.edges[0], stack.homes, ref values, ref output)) {
                    return a64_lowering_error("cannot lower AArch64 jump arguments");
                }

                let patch: Int = output.bytes.length();
                if (!a64_branch(ref output, 0, false)) { return a64_lowering_error("cannot encode AArch64 jump"); }
                fixups.append(A64BranchFixup(offset=patch, target=instruction.edges[0].target, condition=A64Condition.Always, conditional=false));
            } else if (instruction.opcode == WirOpcode.Branch) {
                if (instruction.operands.length() != 1 || instruction.edges.length() != 2) {
                    return a64_lowering_error("branch has an invalid WIR shape");
                }

                let condition: A64Register = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                if (condition == A64Register.None || !a64_compare_zero(ref output, condition, false)) {
                    return a64_lowering_error("cannot materialize the AArch64 branch condition");
                }

                let false_copy: Int = output.bytes.length();
                if (!a64_conditional_branch(ref output, 0, A64Condition.Equal)) {
                    return a64_lowering_error("cannot encode AArch64 conditional branch");
                }

                if (!a64_write_edge(ref program, instruction.edges[0], stack.homes, ref values, ref output)) {
                    return a64_lowering_error("cannot lower the true AArch64 branch arguments");
                }
                let true_patch: Int = output.bytes.length();
                if (!a64_branch(ref output, 0, false)) { return a64_lowering_error("cannot encode AArch64 true branch"); }
                fixups.append(A64BranchFixup(offset=true_patch, target=instruction.edges[0].target, condition=A64Condition.Always, conditional=false));

                if (!a64_patch_branch(ref output, false_copy, output.bytes.length(), A64Condition.Equal, true)) {
                    return a64_lowering_error("cannot patch AArch64 branch argument path");
                }

                if (!a64_write_edge(ref program, instruction.edges[1], stack.homes, ref values, ref output)) {
                    return a64_lowering_error("cannot lower the false AArch64 branch arguments");
                }
                let false_patch: Int = output.bytes.length();
                if (!a64_branch(ref output, 0, false)) { return a64_lowering_error("cannot encode AArch64 branch fallback"); }
                fixups.append(A64BranchFixup(offset=false_patch, target=instruction.edges[1].target, condition=A64Condition.Always, conditional=false));
            } else if (instruction.opcode == WirOpcode.Return) {
                if (instruction.operands.length() > 1) {
                    return a64_lowering_error("return has too many operands");
                }
                if (instruction.operands.length() == 1) {
                    let value: WirValueID = instruction.operands[0];
                    let source: A64Register = a64_materialize(ref program, value, stack.homes, ref values, ref output);
                    let width: Int = a64_scalar_width(ref program, program.arena.values[wir_id_index(UInt32(value))].type_id);
                    if (source == A64Register.None || width == 0) {
                        return a64_lowering_error("cannot materialize the AArch64 return value");
                    }
                    if (source != A64Register.X0 && !a64_mov_register(ref output, A64Register.X0, source, width == 64)) {
                        return a64_lowering_error("cannot move the AArch64 return value");
                    }
                }
                if has_frame {
                    if (!a64_leave_sized_frame(ref output, stack.frame_size)) {
                        return a64_lowering_error("cannot encode the AArch64 function epilogue");
                    }
                } else if (!a64_return(ref output, A64Register.X30)) {
                    return a64_lowering_error("cannot encode the AArch64 return instruction");
                }
            } else {
                return a64_lowering_error("WIR instruction is not covered by initial AArch64 lowering");
            }
            instruction_index++;
        }
        i++;
    }

    if (!a64_patch_branches(ref output, offsets, fixups)) {
        return a64_lowering_error("cannot patch AArch64 control-flow edges");
    }

    return A64LoweringResult(bytes=output.bytes, errors=[], relocations=output.relocations);
}

func a64_lower_module(ref program: WirModule) -> A64ModuleResult {
    if (program.target != "aarch64-unknown-linux-gnu" || program.pointer_bits != 64) {
        return a64_module_error("the AArch64 machine backend does not support this target");
    }

    let text: Vector(Byte) = [];
    let symbols: Vector(A64Symbol) = [];
    let relocations: Vector(A64Relocation) = [];
    let i: Int = 0;

    while (i < program.arena.functions.length()) {
        let function: WirFunction = program.arena.functions[i];
        if (function.blocks.length() != 0) {
            let offset: Int = text.length();
            let lowered: A64LoweringResult = a64_lower_function(ref program, WirFuncID(UInt32(i + 1)));
            if (lowered.errors.length() != 0) {
                return a64_module_error("in function '" + function.name + "': " + lowered.errors[0]);
            }

            let byte_index: Int = 0;
            while (byte_index < lowered.bytes.length()) {
                text.append(lowered.bytes[byte_index]);
                byte_index++;
            }
            let relocation_index: Int = 0;
            while (relocation_index < lowered.relocations.length()) {
                let relocation: A64Relocation = lowered.relocations[relocation_index];
                relocation.offset += UInt32(offset);
                relocations.append(relocation);
                relocation_index++;
            }
            symbols.append(A64Symbol(name=function.name, section=".text", offset=UInt32(offset), external=function.linkage == WirLinkage.Exported));
        } else if (function.linkage == WirLinkage.External) {
            symbols.append(A64Symbol(name=function.name, section="", offset=0U, external=true));
        }
        i++;
    }

    if (symbols.length() == 0) {
        return a64_module_error("the AArch64 module contains no defined functions");
    }

    return A64ModuleResult(
        errors=[],
        sections=[A64Section(name=".text", bytes=text, alignment=4, executable=true, writable=false)],
        symbols=symbols,
        relocations=relocations
    );
}
