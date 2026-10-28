// src/compiler/machine/aarch64/lowering.wl
import * from "model.wl"
import * from "../../wir/model.wl"
import wir_type_layouts from "../../wir/layout.wl"
import * from "encoder.wl"
import * from "allocator.wl"
import * from "memory.wl"
import * from "abi.wl"
import A64HFA, a64_hfa_type from "../../abi/aapcs64.wl"
import * from "fp.wl"
import * from "edges.wl"
import * from "flow.wl"
import * from "stack.wl"
import * from "types.wl"
import * from "values.wl"
import * from "wide.wl"
import machine_layout_valid from "../layout.wl"
import machine_call_signature from "../calls.wl"


func a64_lowering_error(message: String) -> A64LoweringResult {
    return A64LoweringResult(bytes=[], errors=[message], relocations=[]);
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

func a64_atomic_acquire(order: WirMemoryOrder) -> Bool {
    return order == WirMemoryOrder.Acquire || order == WirMemoryOrder.AcquireRelease ||
           order == WirMemoryOrder.SequentiallyConsistent;
}

func a64_atomic_release(order: WirMemoryOrder) -> Bool {
    return order == WirMemoryOrder.Release || order == WirMemoryOrder.AcquireRelease ||
           order == WirMemoryOrder.SequentiallyConsistent;
}

func a64_emit_atomic_rmw(
    ref output: A64CodeBuffer,
    operation: WirAtomicOp,
    address: A64Register,
    input: A64Register,
    old_value: A64Register,
    new_value: A64Register,
    status: A64Register,
    width: Int,
    order: WirMemoryOrder
) -> Bool {
// AAPCS64 only promises the base ARMv8 instruction set, use an LL/SC loop
// here instead of making the whole backend depend on the optional LSE atomics.
    let retry: Int = output.bytes.length();
    let wide: Bool = width == 64;
    if (!a64_load_exclusive(ref output, old_value, address, width, a64_atomic_acquire(order))) {
        return false;
    }

    let encoded: Bool = false;
    if (operation == WirAtomicOp.Exchange) {
        encoded = a64_mov_register(ref output, new_value, input, wide);
    } else if (operation == WirAtomicOp.Add) {
        encoded = a64_add_register(ref output, new_value, old_value, input, wide);
    } else if (operation == WirAtomicOp.Subtract) {
        encoded = a64_sub_register(ref output, new_value, old_value, input, wide);
    } else if (operation == WirAtomicOp.BitAnd) {
        encoded = a64_logical_register(ref output, new_value, old_value, input, 0, wide);
    } else if (operation == WirAtomicOp.BitOr) {
        encoded = a64_logical_register(ref output, new_value, old_value, input, 1, wide);
    } else if (operation == WirAtomicOp.BitXor) {
        encoded = a64_logical_register(ref output, new_value, old_value, input, 2, wide);
    }
    if (!encoded || !a64_store_exclusive(
        ref output,
        status,
        new_value,
        address,
        width,
        a64_atomic_release(order)
    )) {
        return false;
    }

    if (!a64_compare_zero(ref output, status, false)) {
        return false;
    }

    let branch: Int = output.bytes.length();
    return a64_conditional_branch(ref output, retry - branch, A64Condition.NotEqual);
}

func a64_lower_function(ref program: WirModule, function_id: WirFuncID) -> A64LoweringResult {
// standalone callers supply legalized WIR, module lowering inserts required helpers first
    return a64_lower_function_with_layouts(ref program, function_id, wir_type_layouts(program));
}

func a64_lower_function_with_layouts(ref program: WirModule, function_id: WirFuncID, layouts: Vector(WirTypeLayout)) -> A64LoweringResult {
    if (program.target != "aarch64-unknown-linux-gnu" || !machine_layout_valid(program)) {
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
    let output: A64CodeBuffer = a64_new_code_buffer();
    let values: A64ValueMap = a64_new_value_map(ref program, function.blocks);
    a64_mark_edge_registers(ref program, function.blocks, ref values.uses);
    let offsets: Vector(A64BlockOffset) = [];
    let fixups: Vector(A64BranchFixup) = [];
    let stack: A64StackLayout = a64_stack_layout_with_uses(ref program, ref function, layouts, values.uses);
    if (stack.message.length() != 0) { return a64_lowering_error(stack.message); }

    for (let s = 0; s < stack.spills.length(); s++) {
        values.spills.append(A64SpillSlot(value=NO_WIR_VALUE, offset=stack.spills[s]));
        values.free_spills.append(stack.spills.length() - s - 1);
    }
    values.free_count = values.free_spills.length();

    let has_call: Bool = false;
    let i: Int = 0;

    while (i < function.blocks.length()) {
        let scan_block: WirBlock = program.arena.blocks[wir_id_index(UInt32(function.blocks[i]))];
        let j: Int = 0;
        while (j < scan_block.instructions.length()) {
            let scan: WirInstruction = program.arena.instructions[wir_id_index(UInt32(scan_block.instructions[j]))];
            if (scan.opcode == WirOpcode.Call || scan.opcode == WirOpcode.Retain || scan.opcode == WirOpcode.Release ||
                scan.opcode == WirOpcode.NullCheck || scan.opcode == WirOpcode.BoundsCheck) {
                has_call = true;
            }
            j++;
        }
        i++;
    }
    let has_frame: Bool = has_call || stack.frame_size != 0;
    if (has_frame && !a64_enter_sized_frame(ref output, stack.frame_size)) {
        return a64_lowering_error("cannot encode the AArch64 stack frame");
    }
    if (stack.result_pointer_offset >= 0 &&
        !a64_store_integer_at(ref output, A64Register.X8, A64Register.SP, stack.result_pointer_offset, 64)) {
        return a64_lowering_error("cannot save the AArch64 aggregate return pointer");
    }

    let incoming_state: A64ArgumentState = A64ArgumentState(integer=0, floating=0, stack=0);
    i = 0;
    while (i < function.parameters.length()) {
        let parameter: WirValueID = function.parameters[i];
        let ptr value: WirValue = ref program.arena.values[wir_id_index(UInt32(parameter))];
        let location: A64ArgumentLocation = a64_argument_location(ref program, value.type_id, layouts, ref incoming_state);
        let home: A64StackSlot = a64_find_stack_slot(stack.homes, parameter);
        if (!location.valid || home.value == NO_WIR_VALUE) {
            return a64_lowering_error("AArch64 parameter has no valid ABI location or home");
        }

        if (a64_aggregate_type(ref program, value.type_id)) {
            let layout: WirTypeLayout = layouts[wir_id_index(UInt32(value.type_id))];
            let hfa: A64HFA = a64_hfa_type(ref program, value.type_id, layouts);
            if (!layout.valid) {
                return a64_lowering_error("AArch64 aggregate parameter has no valid layout");
            }

            if (location.on_stack) {
                let incoming_offset: Int = stack.frame_size + 16 + location.offset;
                let copied: Bool = false;
                if (location.indirect) {
                    copied = a64_load_integer_at(ref output, A64Register.X10, A64Register.SP, incoming_offset, 64) &&
                             a64_zero_memory(ref output, A64Register.SP, home.offset, home.size) &&
                             a64_copy_memory(ref output, A64Register.SP, home.offset, A64Register.X10, 0, Int(layout.size), A64Register.X9);
                } else {
                    copied = a64_zero_memory(ref output, A64Register.SP, home.offset, home.size) &&
                             a64_copy_memory(ref output, A64Register.SP, home.offset, A64Register.SP, incoming_offset, Int(layout.size), A64Register.X9);
                }
                if (!copied) {
                    return a64_lowering_error("cannot copy an AArch64 stack aggregate parameter");
                }
            } else if (hfa.valid) {
                if (!a64_save_hfa_registers(ref output, home, location.first, hfa)) {
                    return a64_lowering_error("cannot save an AArch64 homogeneous float parameter");
                }
            } else if (!location.indirect) {
                if (!a64_save_aggregate_registers(ref output, home, location.first, location.count)) {
                    return a64_lowering_error("cannot save an AArch64 aggregate parameter");
                }
            } else {
                let incoming: A64Register = a64_argument_register(location.first, false);
                let temporary: A64Register = A64Register.X9;
                if (incoming == A64Register.None || !a64_zero_memory(
                    ref output,
                    A64Register.SP,
                    home.offset,
                    home.size
                ) || !a64_copy_memory(
                    ref output,
                    A64Register.SP,
                    home.offset,
                    incoming,
                    0,
                    Int(layout.size),
                    temporary
                )) {
                    return a64_lowering_error("cannot copy an indirect AArch64 aggregate parameter");
                }
            }

            i++;
            continue;
        }

        let width: Int = a64_integer_width(ref program, value.type_id);
        if (width == 128) {
            let pair: A64RegisterPair = A64RegisterPair(low=A64Register.X9, high=A64Register.X10);
            let loaded: Bool = false;
            if (location.on_stack) {
                let incoming_offset: Int = stack.frame_size + 16 + location.offset;
                loaded = a64_load_integer_at(ref output, pair.low, A64Register.SP, incoming_offset, 64) &&
                         a64_load_integer_at(ref output, pair.high, A64Register.SP, incoming_offset + 8, 64);
            } else {
                pair.low = a64_argument_register(location.first, false);
                pair.high = a64_argument_register(location.first + 1, false);
                loaded = pair.low != A64Register.None && pair.high != A64Register.None;
            }
            if (!loaded || !a64_store_integer_at(ref output, pair.low, A64Register.SP, home.offset, 64) ||
                !a64_store_integer_at(ref output, pair.high, A64Register.SP, home.offset + 8, 64)) {
                return a64_lowering_error("cannot save an AArch64 128-bit argument pair");
            }

            i++;
            continue;
        }

        width = a64_scalar_width(ref program, value.type_id);
        let floating: Bool = a64_scalar_float(ref program, value.type_id);
        if (width == 0) {
            return a64_lowering_error("AArch64 scalar parameter has no register width");
        }
        let incoming: A64Register = A64Register.None;
        if (location.on_stack) {
            incoming = a64_alloc_register(ref program, stack.homes, ref values, ref output, floating);
            let incoming_offset: Int = stack.frame_size + 16 + location.offset;
            let loaded: Bool = false;
            if floating {
                loaded = a64_load_float_at(ref output, incoming, A64Register.SP, incoming_offset, width == 64);
            } else {
                loaded = a64_load_integer_at(ref output, incoming, A64Register.SP, incoming_offset, width);
            }
            if (!loaded) {
                return a64_lowering_error("cannot load an AArch64 stack parameter");
            }
        } else {
            incoming = a64_argument_register(location.first, floating);
        }
        // later indirect parameters use X9/X10 while copying their incoming data,
        // finish homing stack scalars before those scratch registers are touched.
        let saved = false;
        if floating {
            saved = a64_store_float_at(ref output, incoming, A64Register.SP, home.offset, width == 64);
        } else {
            saved = a64_store_integer_at(ref output, incoming, A64Register.SP, home.offset, width);
        }
        if (incoming == A64Register.None || !saved) {
            return a64_lowering_error("cannot save an AArch64 argument register");
        }
        a64_clobber_register(ref values, incoming);
        i++;
    }

    i = 0;
    while (i < stack.homes.slots.length()) {
        let home: A64StackSlot = stack.homes.slots[i];
        let ptr value: WirValue = ref program.arena.values[wir_id_index(UInt32(home.value))];
        if (value.kind == WirValueKind.Constant && a64_aggregate_type(ref program, value.type_id) &&
            !a64_store_value_at(
                ref program,
                home.value,
                A64Register.SP,
                home.offset,
                stack.storage,
                stack.homes,
                layouts,
                ref values,
                ref output
            )) {
            return a64_lowering_error("cannot initialize an AArch64 aggregate constant");
        }
        i++;
    }

    let predecessors: Dict(UInt32, Int) = a64_predecessor_counts(ref program, function.blocks);
    let carry: Bool = false;
    i = 0;
    while (i < function.blocks.length()) {
        if (i != 0 && !carry) {
            // discard the predecessor's allocator state, a join can bind only
            // the entry registers established by every incoming edge.
            a64_clear_bindings(ref values);
        }

        carry = a64_carry_to_next(ref program, function.blocks, predecessors, i);

        let block_id: WirBlockID = function.blocks[i];
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(block_id))];
        let param = 0;
        while (param < block.parameters.length()) {
            let reg = a64_incoming_register(ref values.uses, block.parameters[param]);
            if (reg != A64Register.None && !a64_bind_value(ref values, block.parameters[param], reg, false)) {
                return a64_lowering_error("cannot bind the AArch64 block entry registers");
            }
            param++;
        }
        offsets.append(A64BlockOffset(block=block_id, offset=output.bytes.length()));

        let instruction_index: Int = 0;
        while (instruction_index < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[instruction_index]))];
            if (a64_instruction_uses_wide_int(ref program, instruction) &&
                (a64_is_integer_division(instruction.opcode) || instruction.opcode == WirOpcode.ShiftLeft ||
                 instruction.opcode == WirOpcode.SignedShiftRight || instruction.opcode == WirOpcode.UnsignedShiftRight)) {
                // these wide sequences own extra caller-saved scratch registers,
                // preserve cached values before loading their fixed operands.
                if (!a64_flush_registers(ref program, stack.homes, ref values, ref output)) {
                    return a64_lowering_error("cannot spill AArch64 scalar values before a wide instruction");
                }
                a64_reset_temporaries(ref values);
            }

            if (instruction.opcode == WirOpcode.StackAlloc) {
                // stack slots were assigned before instruction selection
            } else if (instruction.opcode == WirOpcode.Load) {
                if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("load has an invalid WIR shape");
                }

                let slot: A64StackSlot = a64_find_stack_slot(stack.storage, instruction.operands[0]);
                let base: A64Register = A64Register.SP;
                let offset: Int = slot.offset;
                if (slot.value == NO_WIR_VALUE) {
                    base = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                    offset = 0;
                }

                if (base == A64Register.None || !a64_load_value_at(
                    ref program,
                    instruction.type_id,
                    instruction.result,
                    base,
                    offset,
                    stack.homes,
                    layouts,
                    ref values,
                    ref output
                )) {
                    return a64_lowering_error("cannot encode AArch64 load");
                }
            } else if (instruction.opcode == WirOpcode.Store) {
                if (instruction.operands.length() != 2 || instruction.result != NO_WIR_VALUE) {
                    return a64_lowering_error("store has an invalid WIR shape");
                }

                let slot: A64StackSlot = a64_find_stack_slot(stack.storage, instruction.operands[1]);
                let base: A64Register = A64Register.SP;
                let offset: Int = slot.offset;
                if (slot.value == NO_WIR_VALUE) {
                    base = a64_materialize(ref program, instruction.operands[1], stack.homes, ref values, ref output);
                    offset = 0;
                }

                if (base == A64Register.None || !a64_store_value_at(
                    ref program,
                    instruction.operands[0],
                    base,
                    offset,
                    stack.storage,
                    stack.homes,
                    layouts,
                    ref values,
                    ref output
                )) {
                    return a64_lowering_error("cannot encode AArch64 store");
                }
            } else if (instruction.opcode == WirOpcode.StructValue ||
                       instruction.opcode == WirOpcode.ArrayValue) {
                let ptr type: WirType = ref program.arena.types[wir_id_index(UInt32(instruction.type_id))];
                let layout: WirTypeLayout = layouts[wir_id_index(UInt32(instruction.type_id))];
                let home: A64StackSlot = a64_find_stack_slot(stack.homes, instruction.result);
                let count: Int = type.fields.length();
                if (type.kind == WirTypeKind.Array) {
                    if (type.length > UIntSize(2147483647U)) {
                        return a64_lowering_error("AArch64 array constructor exceeds the machine limit");
                    }
                    count = Int(type.length);
                }
                if (!layout.valid || home.value == NO_WIR_VALUE || home.size < Int(layout.size) ||
                    instruction.operands.length() > count ||
                    (instruction.opcode == WirOpcode.StructValue && type.kind != WirTypeKind.Struct) ||
                    (instruction.opcode == WirOpcode.ArrayValue && type.kind != WirTypeKind.Array) ||
                    !a64_zero_memory(ref output, A64Register.SP, home.offset, home.size)) {
                    return a64_lowering_error("AArch64 aggregate constructor has an invalid layout");
                }

                let stride: Int = 0;
                if (type.kind == WirTypeKind.Array) {
                    let element_layout: WirTypeLayout = layouts[wir_id_index(UInt32(type.element))];
                    if (!element_layout.valid || element_layout.size > 2147483647UL) {
                        return a64_lowering_error("AArch64 array element has an invalid layout");
                    }
                    stride = Int(element_layout.size);
                }

                let element_index: Int = 0;
                while (element_index < instruction.operands.length()) {
                    let offset: Int = element_index * stride;
                    if (type.kind == WirTypeKind.Struct) {
                        offset = Int(layout.field_offsets[element_index]);
                    }
                    if (!a64_store_value_at(
                        ref program,
                        instruction.operands[element_index],
                        A64Register.SP,
                        home.offset + offset,
                        stack.storage,
                        stack.homes,
                        layouts,
                        ref values,
                        ref output
                    )) {
                        return a64_lowering_error("cannot initialize an AArch64 aggregate member");
                    }
                    element_index++;
                }
            } else if (instruction.opcode == WirOpcode.Field || instruction.opcode == WirOpcode.Index) {
                if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("aggregate extraction has an invalid WIR shape");
                }

                let aggregate_id: WirValueID = instruction.operands[0];
                let aggregate: WirValue = program.arena.values[wir_id_index(UInt32(aggregate_id))];
                let ptr type: WirType = ref program.arena.types[wir_id_index(UInt32(aggregate.type_id))];
                let layout: WirTypeLayout = layouts[wir_id_index(UInt32(aggregate.type_id))];
                let home: A64StackSlot = a64_find_stack_slot(stack.homes, aggregate_id);
                let index: WirValue = program.arena.values[
                    wir_id_index(UInt32(instruction.operands[1]))
                ];
                if (!layout.valid || index.kind != WirValueKind.Integer) {
                    return a64_lowering_error("AArch64 aggregate extraction requires a valid layout and constant index");
                }

                let offset: Int = 0;
                if (instruction.opcode == WirOpcode.Field) {
                    if (type.kind != WirTypeKind.Struct || index.integer >= UInt128(type.fields.length())) {
                        return a64_lowering_error("AArch64 aggregate field index is out of range");
                    }
                    offset = Int(layout.field_offsets[Int(index.integer)]);
                } else {
                    if (type.kind != WirTypeKind.Array || index.integer >= UInt128(type.length)) {
                        return a64_lowering_error("AArch64 aggregate element index is out of range");
                    }
                    let element_layout: WirTypeLayout = layouts[wir_id_index(UInt32(type.element))];
                    if (!element_layout.valid || element_layout.size > 2147483647UL) {
                        return a64_lowering_error("AArch64 aggregate element has an invalid layout");
                    }
                    offset = Int(index.integer) * Int(element_layout.size);
                }

                if (home.value == NO_WIR_VALUE && aggregate.kind == WirValueKind.Constant) {
                    let constant_index: Int = wir_id_index(aggregate.owner);
                    let result_home: A64StackSlot = a64_find_stack_slot(stack.homes, instruction.result);
                    if (constant_index < 0 || constant_index >= program.arena.constants.length() ||
                        result_home.value == NO_WIR_VALUE) {
                        return a64_lowering_error("AArch64 constant aggregate member has no storage");
                    }

                    let ptr constant: WirConstant = ref program.arena.constants[constant_index];
                    if (constant.kind == WirConstKind.Zero) {
                        if (!a64_zero_memory(ref output, A64Register.SP, result_home.offset, result_home.size)) {
                            return a64_lowering_error("cannot extract an AArch64 zero aggregate member");
                        }
                    } else if (constant.kind == WirConstKind.Aggregate &&
                               index.integer < UInt128(constant.elements.length())) {
                        if (!a64_store_value_at(
                            ref program,
                            constant.elements[Int(index.integer)],
                            A64Register.SP,
                            result_home.offset,
                            stack.storage,
                            stack.homes,
                            layouts,
                            ref values,
                            ref output
                        )) {
                            return a64_lowering_error("cannot extract an AArch64 constant aggregate member");
                        }
                    } else {
                        return a64_lowering_error("AArch64 constant aggregate member is unavailable");
                    }
                } else if (home.value == NO_WIR_VALUE) {
                    return a64_lowering_error("AArch64 aggregate value has no storage for extraction");
                } else if (!a64_load_value_at(
                    ref program,
                    instruction.type_id,
                    instruction.result,
                    A64Register.SP,
                    home.offset + offset,
                    stack.homes,
                    layouts,
                    ref values,
                    ref output
                )) {
                    return a64_lowering_error("cannot extract an AArch64 aggregate member");
                }
            } else if (instruction.opcode == WirOpcode.AtomicLoad) {
                if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("atomic load has an invalid WIR shape");
                }

                let width: Int = a64_integer_bits(ref program, instruction.type_id);
                let home_width: Int = a64_scalar_width(ref program, instruction.type_id);
                let address: A64Register = a64_materialize(
                    ref program,
                    instruction.operands[0],
                    stack.homes,
                    ref values,
                    ref output
                );
                let destination: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, false);
                if (address == A64Register.None || destination == A64Register.None ||
                    !a64_atomic_load(
                        ref output,
                        destination,
                        address,
                        width,
                        a64_atomic_acquire(instruction.memory_order)
                    ) ||
                    !a64_save_home(ref values, ref output, stack.homes, instruction.result, destination, home_width)) {
                    return a64_lowering_error("cannot encode AArch64 atomic load");
                }
            } else if (instruction.opcode == WirOpcode.AtomicStore) {
                if (instruction.operands.length() != 2 || instruction.result != NO_WIR_VALUE) {
                    return a64_lowering_error("atomic store has an invalid WIR shape");
                }

                let value_type: WirTypeID = program.arena.values[
                    wir_id_index(UInt32(instruction.operands[0]))
                ].type_id;
                let width: Int = a64_integer_bits(ref program, value_type);
                let source: A64Register = a64_materialize(
                    ref program,
                    instruction.operands[0],
                    stack.homes,
                    ref values,
                    ref output
                );
                let address: A64Register = a64_materialize(
                    ref program,
                    instruction.operands[1],
                    stack.homes,
                    ref values,
                    ref output
                );
                if (source == A64Register.None || address == A64Register.None ||
                    !a64_atomic_store(
                        ref output,
                        source,
                        address,
                        width,
                        a64_atomic_release(instruction.memory_order)
                    )) {
                    return a64_lowering_error("cannot encode AArch64 atomic store");
                }
            } else if (instruction.opcode == WirOpcode.AtomicRmw) {
                if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("atomic RMW has an invalid WIR shape");
                }

                let width: Int = a64_integer_bits(ref program, instruction.type_id);
                let home_width: Int = a64_scalar_width(ref program, instruction.type_id);
                let address: A64Register = a64_materialize(
                    ref program,
                    instruction.operands[0],
                    stack.homes,
                    ref values,
                    ref output
                );
                let input: A64Register = a64_materialize(
                    ref program,
                    instruction.operands[1],
                    stack.homes,
                    ref values,
                    ref output
                );
                let old_value: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, false);
                let new_value: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, false);
                let status: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, false);
                if (address == A64Register.None || input == A64Register.None || old_value == A64Register.None ||
                    new_value == A64Register.None || status == A64Register.None ||
                    !a64_emit_atomic_rmw(
                        ref output,
                        instruction.atomic_op,
                        address,
                        input,
                        old_value,
                        new_value,
                        status,
                        width,
                        instruction.memory_order
                    ) ||
                    !a64_save_home(ref values, ref output, stack.homes, instruction.result, old_value, home_width)) {
                    return a64_lowering_error("cannot encode AArch64 atomic read-modify-write");
                }
            } else if (instruction.opcode == WirOpcode.FieldAddress ||
                       instruction.opcode == WirOpcode.IndexAddress) {
                if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("aggregate address has an invalid WIR shape");
                }

                let base_id: WirValueID = instruction.operands[0];
                let base_value: WirValue = program.arena.values[wir_id_index(UInt32(base_id))];
                let pointer: WirType = program.arena.types[wir_id_index(UInt32(base_value.type_id))];
                if (pointer.kind != WirTypeKind.Pointer) {
                    return a64_lowering_error("aggregate address requires a pointer base");
                }

                let base: A64Register = a64_materialize_address(
                    ref program,
                    base_id,
                    stack.storage,
                    stack.homes,
                    ref values,
                    ref output
                );
                let destination: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, false);
                if (base == A64Register.None || destination == A64Register.None) {
                    return a64_lowering_error("cannot materialize an AArch64 aggregate address");
                }

                if (instruction.opcode == WirOpcode.FieldAddress) {
                    let layout: WirTypeLayout = layouts[wir_id_index(UInt32(pointer.element))];
                    let field: WirValue = program.arena.values[
                        wir_id_index(UInt32(instruction.operands[1]))
                    ];
                    if (!layout.valid || field.kind != WirValueKind.Integer ||
                        field.integer >= UInt128(layout.field_offsets.length())) {
                        return a64_lowering_error("AArch64 field address has an invalid field index");
                    }

                    let offset: UInt64 = layout.field_offsets[Int(field.integer)];
                    let encoded: Bool = false;
                    if (offset == 0UL) {
                        encoded = a64_mov_register(ref output, destination, base, true);
                    } else if (offset <= 4095UL) {
                        encoded = a64_add_immediate(ref output, destination, base, Int(offset), true);
                    } else {
                        let temporary: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, false);
                        encoded = temporary != A64Register.None &&
                                  a64_mov_immediate(ref output, temporary, offset, true) &&
                                  a64_add_register(ref output, destination, base, temporary, true);
                    }
                    if (!encoded) {
                        return a64_lowering_error("cannot encode an AArch64 field address");
                    }
                } else {
                    let element_type: WirTypeID = pointer.element;
                    let element: WirType = program.arena.types[wir_id_index(UInt32(element_type))];
                    if (element.kind == WirTypeKind.Array) {
                        element_type = element.element;
                    }

                    let layout: WirTypeLayout = layouts[wir_id_index(UInt32(element_type))];
                    let index_id: WirValueID = instruction.operands[1];
                    let index_value: WirValue = program.arena.values[wir_id_index(UInt32(index_id))];
                    let index_bits: Int = a64_integer_bits(ref program, index_value.type_id);
                    let index: A64Register = a64_materialize(
                        ref program,
                        index_id,
                        stack.homes,
                        ref values,
                        ref output
                    );
                    let scaled: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, false);
                    if (!layout.valid || layout.size == 0UL || index == A64Register.None ||
                        scaled == A64Register.None || index_bits <= 0 || index_bits > 64) {
                        return a64_lowering_error("AArch64 index address has an invalid element layout");
                    }

                    let extended: Bool = false;
                    if (index_bits < 64) {
                        extended = a64_extend_integer(
                            ref output,
                            scaled,
                            index,
                            index_bits,
                            a64_integer_signed(ref program, index_value.type_id),
                            true
                        );
                    } else {
                        extended = a64_mov_register(ref output, scaled, index, true);
                    }
                    if (!extended) {
                        return a64_lowering_error("cannot extend an AArch64 aggregate index");
                    }

                    if (layout.size != 1UL) {
                        let stride: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, false);
                        if (stride == A64Register.None ||
                            !a64_mov_immediate(ref output, stride, layout.size, true) ||
                            !a64_multiply_register(ref output, scaled, scaled, stride, true)) {
                            return a64_lowering_error("cannot scale an AArch64 aggregate index");
                        }
                    }
                    if (!a64_add_register(ref output, destination, base, scaled, true)) {
                        return a64_lowering_error("cannot encode an AArch64 index address");
                    }
                }

                if (!a64_save_home(ref values, ref output, stack.homes, instruction.result, destination, 64)) {
                    return a64_lowering_error("cannot save an AArch64 aggregate address");
                }
            } else if (instruction.opcode == WirOpcode.Bitcast && instruction.operands.length() == 1 &&
                       (a64_scalar_float(ref program, instruction.type_id) ||
                        a64_scalar_float(ref program, program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id))) {
                if (instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("floating-point bitcast has no result");
                }

                let source_id: WirValueID = instruction.operands[0];
                let source_type: WirTypeID = program.arena.values[wir_id_index(UInt32(source_id))].type_id;
                let source_width: Int = a64_scalar_width(ref program, source_type);
                let target_width: Int = a64_scalar_width(ref program, instruction.type_id);
                let source_float: Bool = a64_scalar_float(ref program, source_type);
                let target_float: Bool = a64_scalar_float(ref program, instruction.type_id);
                let source: A64Register = a64_materialize(ref program, source_id, stack.homes, ref values, ref output);
                let destination: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, target_float);
                let encoded: Bool = source_width == target_width && (target_width == 32 || target_width == 64) &&
                                    source != A64Register.None && destination != A64Register.None;
                if (encoded && source_float && target_float) {
                    encoded = a64_float_move(ref output, destination, source, target_width == 64);
                } else if (encoded && source_float) {
                    encoded = a64_float_to_bits(ref output, destination, source, target_width == 64);
                } else if (encoded && target_float) {
                    encoded = a64_float_from_bits(ref output, destination, source, target_width == 64);
                }
                if (!encoded || !a64_save_home(ref values, ref output, stack.homes, instruction.result, destination, target_width)) {
                    return a64_lowering_error("cannot encode an AArch64 floating-point bitcast");
                }
            } else if (instruction.opcode == WirOpcode.Bitcast ||
                       instruction.opcode == WirOpcode.PointerToInt ||
                       instruction.opcode == WirOpcode.IntToPointer) {
                if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("pointer cast has an invalid WIR shape");
                }

                let source_id: WirValueID = instruction.operands[0];
                let source_type: WirTypeID = program.arena.values[wir_id_index(UInt32(source_id))].type_id;
                let source_width: Int = a64_integer_width(ref program, source_type);
                let target_width: Int = a64_integer_width(ref program, instruction.type_id);
                if (source_width == 0) { source_width = a64_scalar_width(ref program, source_type); }
                if (target_width == 0) { target_width = a64_scalar_width(ref program, instruction.type_id); }

                if (source_width == 0 || target_width == 0 || a64_scalar_float(ref program, source_type) ||
                    a64_scalar_float(ref program, instruction.type_id)) {
                    return a64_lowering_error("AArch64 pointer cast has unsupported types");
                }

                if (source_width == 128 && target_width == 128) {
                    let source: A64RegisterPair = a64_materialize_pair(
                        ref program,
                        source_id,
                        stack.homes,
                        ref values,
                        ref output
                    );
                    if (source.low == A64Register.None || source.high == A64Register.None ||
                        !a64_save_pair(ref values, ref output, stack.homes, instruction.result, source)) {
                        return a64_lowering_error("cannot encode an AArch64 128-bit bitcast");
                    }
                } else if (target_width == 128) {
                    let source: A64Register = a64_materialize_address(
                        ref program,
                        source_id,
                        stack.storage,
                        stack.homes,
                        ref values,
                        ref output
                    );
                    let destination: A64RegisterPair = a64_alloc_pair(ref program, stack.homes, ref values, ref output);
                    let encoded: Bool = source != A64Register.None && destination.low != A64Register.None &&
                                        destination.high != A64Register.None &&
                                        a64_mov_register(ref output, destination.low, source, true) &&
                                        a64_mov_immediate(ref output, destination.high, 0UL, true);
                    if (!encoded || !a64_save_pair(ref values, ref output, stack.homes, instruction.result, destination)) {
                        return a64_lowering_error("cannot cast an AArch64 pointer to a 128-bit integer");
                    }
                } else if (source_width == 128) {
                    let source: A64RegisterPair = a64_materialize_pair(ref program, source_id, stack.homes, ref values, ref output);
                    let destination: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, false);
                    let encoded: Bool = source.low != A64Register.None && destination != A64Register.None &&
                                        a64_mov_register(ref output, destination, source.low, target_width == 64);
                    if (!encoded || !a64_save_home(ref values, ref output, stack.homes, instruction.result, destination, target_width)) {
                        return a64_lowering_error("cannot cast a 128-bit integer to an AArch64 pointer");
                    }
                } else {
                    let source: A64Register = a64_materialize_address(
                        ref program,
                        source_id,
                        stack.storage,
                        stack.homes,
                        ref values,
                        ref output
                    );
                    let destination: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, false);
                    let encoded: Bool = source != A64Register.None && destination != A64Register.None;
                    if (encoded && instruction.opcode == WirOpcode.IntToPointer && source_width < 64) {
                        let bits: Int = a64_integer_bits(ref program, source_type);
                        encoded = bits > 0 && a64_extend_integer(ref output, destination, source, bits, false, true);
                    } else if encoded {
                        encoded = a64_mov_register(ref output, destination, source, target_width == 64);
                    }
                    if (!encoded || !a64_save_home(ref values, ref output, stack.homes, instruction.result, destination, target_width)) {
                        return a64_lowering_error("cannot encode an AArch64 pointer cast");
                    }
                }
            } else if (instruction.opcode == WirOpcode.Truncate ||
                       instruction.opcode == WirOpcode.SignExtend ||
                       instruction.opcode == WirOpcode.ZeroExtend) {
                if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("integer cast has an invalid WIR shape");
                }

                let source_id: WirValueID = instruction.operands[0];
                let source_type: WirTypeID = program.arena.values[wir_id_index(UInt32(source_id))].type_id;
                let source_bits: Int = a64_integer_bits(ref program, source_type);
                let target_bits: Int = a64_integer_bits(ref program, instruction.type_id);
                if (source_bits == 0 || target_bits == 0) {
                    return a64_lowering_error("AArch64 integer cast has unsupported types");
                }

                if (target_bits == 128) {
                    let source: A64Register = a64_materialize(ref program, source_id, stack.homes, ref values, ref output);
                    let destination: A64RegisterPair = a64_alloc_pair(ref program, stack.homes, ref values, ref output);
                    let amount: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, false);
                    let encoded: Bool = source != A64Register.None && destination.low != A64Register.None &&
                                        destination.high != A64Register.None && amount != A64Register.None;
                    if (encoded && source_bits < 64) {
                        encoded = a64_extend_integer(
                            ref output,
                            destination.low,
                            source,
                            source_bits,
                            instruction.opcode == WirOpcode.SignExtend,
                            true
                        );
                    } else if encoded {
                        encoded = a64_mov_register(ref output, destination.low, source, true);
                    }
                    if (encoded && instruction.opcode == WirOpcode.SignExtend) {
                        encoded = a64_mov_immediate(ref output, amount, 63UL, true) &&
                                  a64_shift_register(ref output, destination.high, destination.low, amount, 1, true);
                    } else if encoded {
                        encoded = a64_mov_immediate(ref output, destination.high, 0UL, true);
                    }
                    if (!encoded || !a64_save_pair(ref values, ref output, stack.homes, instruction.result, destination)) {
                        return a64_lowering_error("cannot extend an AArch64 integer to 128 bits");
                    }
                } else if (source_bits == 128) {
                    let source: A64RegisterPair = a64_materialize_pair(ref program, source_id, stack.homes, ref values, ref output);
                    let destination: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, false);
                    let target_width: Int = a64_scalar_width(ref program, instruction.type_id);
                    let encoded: Bool = source.low != A64Register.None && destination != A64Register.None && target_width != 0;
                    if (encoded && target_bits < target_width) {
                        encoded = a64_extend_integer(
                            ref output,
                            destination,
                            source.low,
                            target_bits,
                            a64_integer_signed(ref program, instruction.type_id),
                            target_width == 64
                        );
                    } else if encoded {
                        encoded = a64_mov_register(ref output, destination, source.low, target_width == 64);
                    }
                    if (!encoded || !a64_save_home(ref values, ref output, stack.homes, instruction.result, destination, target_width)) {
                        return a64_lowering_error("cannot truncate an AArch64 128-bit integer");
                    }
                } else {
                    let source: A64Register = a64_materialize(ref program, source_id, stack.homes, ref values, ref output);
                    let destination: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, false);
                    let target_width: Int = a64_scalar_width(ref program, instruction.type_id);
                    let extend_bits: Int = source_bits;
                    let signed: Bool = instruction.opcode == WirOpcode.SignExtend;
                    if (instruction.opcode == WirOpcode.Truncate) {
                        extend_bits = target_bits;
                        signed = a64_integer_signed(ref program, instruction.type_id);
                    }
                    if (source == A64Register.None || destination == A64Register.None || target_width == 0 ||
                        !a64_extend_integer(ref output, destination, source, extend_bits, signed, target_width == 64) ||
                        !a64_save_home(ref values, ref output, stack.homes, instruction.result, destination, target_width)) {
                        return a64_lowering_error("cannot encode AArch64 integer cast");
                    }
                }
            } else if (instruction.opcode == WirOpcode.FloatExtend ||
                       instruction.opcode == WirOpcode.FloatTruncate) {
                if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("floating-point width conversion has an invalid WIR shape");
                }

                let source: A64Register = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let destination: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, true);
                let target_width: Int = a64_scalar_width(ref program, instruction.type_id);
                let extend: Bool = instruction.opcode == WirOpcode.FloatExtend;
                if (source == A64Register.None || destination == A64Register.None ||
                    (target_width != 32 && target_width != 64) ||
                    !a64_convert_float(ref output, destination, source, extend) ||
                    !a64_save_home(ref values, ref output, stack.homes, instruction.result, destination, target_width)) {
                    return a64_lowering_error("cannot encode an AArch64 floating-point width conversion");
                }
            } else if (instruction.opcode == WirOpcode.SignedIntToFloat ||
                       instruction.opcode == WirOpcode.UnsignedIntToFloat) {
                if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("integer to float conversion has an invalid WIR shape");
                }

                let source_id: WirValueID = instruction.operands[0];
                let source_type: WirTypeID = program.arena.values[wir_id_index(UInt32(source_id))].type_id;
                let source_width: Int = a64_integer_width(ref program, source_type);
                let target_width: Int = a64_scalar_width(ref program, instruction.type_id);
                let source: A64Register = a64_materialize(ref program, source_id, stack.homes, ref values, ref output);
                let destination: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, true);
                if ((source_width != 32 && source_width != 64) ||
                    (target_width != 32 && target_width != 64) ||
                    source == A64Register.None || destination == A64Register.None ||
                    !a64_int_to_float(
                        ref output,
                        destination,
                        source,
                        instruction.opcode == WirOpcode.SignedIntToFloat,
                        source_width == 64,
                        target_width == 64
                    ) ||
                    !a64_save_home(ref values, ref output, stack.homes, instruction.result, destination, target_width)) {
                    return a64_lowering_error("cannot encode an AArch64 integer to float conversion");
                }
            } else if (instruction.opcode == WirOpcode.FloatToSignedInt ||
                       instruction.opcode == WirOpcode.FloatToUnsignedInt) {
                if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("float to integer conversion has an invalid WIR shape");
                }

                let source_id: WirValueID = instruction.operands[0];
                let source_type: WirTypeID = program.arena.values[wir_id_index(UInt32(source_id))].type_id;
                let source_width: Int = a64_scalar_width(ref program, source_type);
                let target_width: Int = a64_integer_width(ref program, instruction.type_id);
                let source: A64Register = a64_materialize(ref program, source_id, stack.homes, ref values, ref output);
                let destination: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, false);
                if ((source_width != 32 && source_width != 64) ||
                    (target_width != 32 && target_width != 64) ||
                    source == A64Register.None || destination == A64Register.None ||
                    !a64_float_to_int(
                        ref output,
                        destination,
                        source,
                        instruction.opcode == WirOpcode.FloatToSignedInt,
                        source_width == 64,
                        target_width == 64
                    ) ||
                    !a64_save_home(ref values, ref output, stack.homes, instruction.result, destination, target_width)) {
                    return a64_lowering_error("cannot encode an AArch64 float to integer conversion");
                }
            } else if (a64_integer_width(ref program, instruction.type_id) == 128 &&
                       (instruction.opcode == WirOpcode.Add || instruction.opcode == WirOpcode.Subtract ||
                        instruction.opcode == WirOpcode.BitAnd || instruction.opcode == WirOpcode.BitOr ||
                        instruction.opcode == WirOpcode.BitXor)) {
                if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("128-bit integer operation has an invalid WIR shape");
                }

                let left: A64RegisterPair = a64_materialize_pair(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let right: A64RegisterPair = a64_materialize_pair(ref program, instruction.operands[1], stack.homes, ref values, ref output);
                let destination: A64RegisterPair = a64_alloc_pair(ref program, stack.homes, ref values, ref output);
                if (left.low == A64Register.None || left.high == A64Register.None ||
                    right.low == A64Register.None || right.high == A64Register.None ||
                    destination.low == A64Register.None || destination.high == A64Register.None ||
                    !a64_wide_binary(ref output, instruction.opcode, destination, left, right) ||
                    !a64_save_pair(ref values, ref output, stack.homes, instruction.result, destination)) {
                    return a64_lowering_error("cannot encode AArch64 128-bit integer operation");
                }
            } else if (a64_integer_width(ref program, instruction.type_id) == 128 &&
                       instruction.opcode == WirOpcode.Multiply) {
                if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("128-bit multiply has an invalid WIR shape");
                }

                let left: A64RegisterPair = a64_materialize_pair(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let right: A64RegisterPair = a64_materialize_pair(ref program, instruction.operands[1], stack.homes, ref values, ref output);
                let destination: A64RegisterPair = a64_alloc_pair(ref program, stack.homes, ref values, ref output);
                let temporary: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, false);
                if (left.low == A64Register.None || left.high == A64Register.None ||
                    right.low == A64Register.None || right.high == A64Register.None ||
                    destination.low == A64Register.None || destination.high == A64Register.None ||
                    temporary == A64Register.None ||
                    !a64_wide_multiply(ref output, destination, left, right, temporary) ||
                    !a64_save_pair(ref values, ref output, stack.homes, instruction.result, destination)) {
                    return a64_lowering_error("cannot encode AArch64 128-bit multiply");
                }
            } else if (a64_integer_width(ref program, instruction.type_id) == 128 &&
                       (instruction.opcode == WirOpcode.ShiftLeft ||
                        instruction.opcode == WirOpcode.SignedShiftRight ||
                        instruction.opcode == WirOpcode.UnsignedShiftRight)) {
                if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("128-bit shift has an invalid WIR shape");
                }

                let source: A64RegisterPair = a64_materialize_pair(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let amount: A64RegisterPair = a64_materialize_pair(ref program, instruction.operands[1], stack.homes, ref values, ref output);
                let destination: A64RegisterPair = a64_alloc_pair(ref program, stack.homes, ref values, ref output);
                let count: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, false);
                // four input words, two result words and count fill X9-X15.
                // X0/X1 are free after entry arguments have reached their homes.
                let work = A64Register.X0;
                let cross = A64Register.X1;
                if (source.low == A64Register.None || source.high == A64Register.None || amount.low == A64Register.None ||
                    destination.low == A64Register.None || destination.high == A64Register.None ||
                    count == A64Register.None ||
                    !a64_wide_shift(ref output, instruction.opcode, destination, source, amount.low, count, work, cross) ||
                    !a64_save_pair(ref values, ref output, stack.homes, instruction.result, destination)) {
                    return a64_lowering_error("cannot encode AArch64 128-bit shift");
                }
            } else if (a64_is_integer_binary(instruction.opcode) && !a64_scalar_float(ref program, instruction.type_id)) {
                if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("integer arithmetic has an invalid WIR shape");
                }

                let left: A64Register = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let right: A64Register = a64_materialize(ref program, instruction.operands[1], stack.homes, ref values, ref output);
                let destination: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, false);
                let width: Int = a64_scalar_width(ref program, instruction.type_id);
                if (left == A64Register.None || right == A64Register.None || destination == A64Register.None || width == 0) {
                    return a64_lowering_error("AArch64 integer arithmetic ran out of temporary registers");
                }

                let encoded: Bool = a64_emit_integer_binary(ref output, instruction.opcode, destination, left, right, width == 64);
                if (!encoded || !a64_save_home(ref values, ref output, stack.homes, instruction.result, destination, width)) {
                    return a64_lowering_error("cannot encode AArch64 integer arithmetic");
                }
            } else if (a64_is_integer_division(instruction.opcode) &&
                       a64_integer_width(ref program, instruction.type_id) == 128) {
                if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE ||
                    !a64_materialize_pair_into(ref program, instruction.operands[0], stack.homes, A64RegisterPair(low=A64Register.X0, high=A64Register.X1), ref output) ||
                    !a64_materialize_pair_into(ref program, instruction.operands[1], stack.homes, A64RegisterPair(low=A64Register.X2, high=A64Register.X3), ref output)) {
                    return a64_lowering_error("128-bit division has an invalid WIR shape");
                }

                let signed: Bool = instruction.opcode == WirOpcode.SignedDivide || instruction.opcode == WirOpcode.SignedRemainder;
                let remainder: Bool = instruction.opcode == WirOpcode.SignedRemainder || instruction.opcode == WirOpcode.UnsignedRemainder;
                // The software divider owns X0-X12 while its emitted loop runs.
                a64_clear_bindings(ref values);
                let result: A64RegisterPair = a64_wide_divide(ref output, signed, remainder);
                if (result.low == A64Register.None || result.high == A64Register.None ||
                    !a64_save_pair(ref values, ref output, stack.homes, instruction.result, result)) {
                    return a64_lowering_error("cannot encode AArch64 128-bit division");
                }
            } else if (a64_is_integer_division(instruction.opcode)) {
                if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("integer division has an invalid WIR shape");
                }

                let left: A64Register = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let right: A64Register = a64_materialize(ref program, instruction.operands[1], stack.homes, ref values, ref output);
                let quotient: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, false);
                let destination: A64Register = quotient;
                let width: Int = a64_scalar_width(ref program, instruction.type_id);
                let signed: Bool = instruction.opcode == WirOpcode.SignedDivide || instruction.opcode == WirOpcode.SignedRemainder;
                let remainder: Bool = instruction.opcode == WirOpcode.SignedRemainder || instruction.opcode == WirOpcode.UnsignedRemainder;
                if remainder { destination = a64_alloc_register(ref program, stack.homes, ref values, ref output, false); }

                let encoded: Bool = a64_divide_register(ref output, quotient, left, right, signed, width == 64);
                if (encoded && remainder) {
                    encoded = a64_multiply_subtract(ref output, destination, quotient, right, left, width == 64);
                }
                if (left == A64Register.None || right == A64Register.None || quotient == A64Register.None ||
                    destination == A64Register.None || width == 0 || !encoded ||
                    !a64_save_home(ref values, ref output, stack.homes, instruction.result, destination, width)) {
                    return a64_lowering_error("cannot encode AArch64 integer division");
                }
            } else if (a64_is_float_binary(instruction.opcode) && a64_scalar_float(ref program, instruction.type_id)) {
                if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("floating-point arithmetic has an invalid WIR shape");
                }

                let left: A64Register = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let right: A64Register = a64_materialize(ref program, instruction.operands[1], stack.homes, ref values, ref output);
                let destination: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, true);
                let width: Int = a64_scalar_width(ref program, instruction.type_id);
                if (left == A64Register.None || right == A64Register.None || destination == A64Register.None || width == 0 ||
                    !a64_emit_float_binary(ref output, instruction.opcode, destination, left, right, width == 64) ||
                    !a64_save_home(ref values, ref output, stack.homes, instruction.result, destination, width)) {
                    return a64_lowering_error("cannot encode AArch64 floating-point arithmetic");
                }
            } else if (instruction.opcode == WirOpcode.FloatNegate) {
                if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("floating-point negate has an invalid WIR shape");
                }

                let source: A64Register = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let destination: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, true);
                let width: Int = a64_scalar_width(ref program, instruction.type_id);
                if (source == A64Register.None || destination == A64Register.None || width == 0 ||
                    !a64_float_negate(ref output, destination, source, width == 64) ||
                    !a64_save_home(ref values, ref output, stack.homes, instruction.result, destination, width)) {
                    return a64_lowering_error("cannot encode AArch64 floating-point negate");
                }
            } else if (a64_is_integer_comparison(instruction.opcode) && instruction.operands.length() == 2 &&
                       a64_integer_width(ref program, program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id) == 128) {
                if (instruction.result == NO_WIR_VALUE || instruction.type_id != program.bool_type) {
                    return a64_lowering_error("128-bit comparison has an invalid WIR shape");
                }

                let left: A64RegisterPair = a64_materialize_pair(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let right: A64RegisterPair = a64_materialize_pair(ref program, instruction.operands[1], stack.homes, ref values, ref output);
                let destination: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, false);
                let first: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, false);
                let second: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, false);
                if (left.low == A64Register.None || left.high == A64Register.None ||
                    right.low == A64Register.None || right.high == A64Register.None ||
                    destination == A64Register.None || first == A64Register.None || second == A64Register.None ||
                    !a64_wide_compare(ref output, instruction.opcode, destination, first, second, left, right) ||
                    !a64_save_home(ref values, ref output, stack.homes, instruction.result, destination, 32)) {
                    return a64_lowering_error("cannot encode AArch64 128-bit comparison");
                }
            } else if (a64_is_float_comparison(instruction.opcode) && instruction.operands.length() == 2 &&
                       a64_scalar_float(ref program, program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id)) {
                if (instruction.result == NO_WIR_VALUE || instruction.type_id != program.bool_type) {
                    return a64_lowering_error("floating-point comparison has an invalid WIR shape");
                }

                let left_value: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
                let right_value: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[1]))];
                let left: A64Register = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let right: A64Register = a64_materialize(ref program, instruction.operands[1], stack.homes, ref values, ref output);
                let destination: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, false);
                let width: Int = a64_scalar_width(ref program, left_value.type_id);
                let condition: A64Condition = a64_float_condition(instruction.opcode);
                if (left_value.type_id != right_value.type_id || left == A64Register.None || right == A64Register.None ||
                    destination == A64Register.None || width == 0 || condition == A64Condition.Never ||
                    !a64_float_compare(ref output, left, right, width == 64) ||
                    !a64_set_condition(ref output, destination, condition) ||
                    !a64_save_home(ref values, ref output, stack.homes, instruction.result, destination, 32)) {
                    return a64_lowering_error("cannot encode AArch64 floating-point comparison");
                }
            } else if (a64_is_integer_comparison(instruction.opcode)) {
                if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("integer comparison has an invalid WIR shape");
                }

                let input_type: WirTypeID = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id;
                let kind = program.arena.types[wir_id_index(UInt32(input_type))].kind;
                let left = A64Register.None;
                let right = A64Register.None;
                if (kind == WirTypeKind.Pointer || kind == WirTypeKind.Function) {
                    // load forwarding can expose a StackAlloc address directly, it has no saved value home.
                    left = a64_materialize_address(ref program, instruction.operands[0], stack.storage, stack.homes, ref values, ref output);
                    right = a64_materialize_address(ref program, instruction.operands[1], stack.storage, stack.homes, ref values, ref output);
                } else {
                    left = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                    right = a64_materialize(ref program, instruction.operands[1], stack.homes, ref values, ref output);
                }
                let destination: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, false);
                let width: Int = a64_scalar_width(ref program, input_type);
                let condition: A64Condition = a64_comparison_condition(instruction.opcode);

                if (left == A64Register.None || right == A64Register.None || destination == A64Register.None || width == 0 ||
                    condition == A64Condition.Never || !a64_compare_register(ref output, left, right, width == 64) ||
                    !a64_set_condition(ref output, destination, condition) ||
                    !a64_save_home(ref values, ref output, stack.homes, instruction.result, destination, 32)) {
                    return a64_lowering_error("cannot encode AArch64 integer comparison");
                }
            } else if (a64_integer_width(ref program, instruction.type_id) == 128 &&
                       (instruction.opcode == WirOpcode.Negate || instruction.opcode == WirOpcode.Not || instruction.opcode == WirOpcode.Abs)) {
                if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("128-bit unary operation has an invalid WIR shape");
                }

                let source: A64RegisterPair = a64_materialize_pair(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let destination: A64RegisterPair = a64_alloc_pair(ref program, stack.homes, ref values, ref output);
                let temporary: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, false);
                if (source.low == A64Register.None || source.high == A64Register.None ||
                    destination.low == A64Register.None || destination.high == A64Register.None ||
                    temporary == A64Register.None ||
                    !a64_wide_unary(ref output, instruction.opcode, destination, source, temporary) ||
                    !a64_save_pair(ref values, ref output, stack.homes, instruction.result, destination)) {
                    return a64_lowering_error("cannot encode AArch64 128-bit unary operation");
                }
            } else if (instruction.opcode == WirOpcode.Negate || instruction.opcode == WirOpcode.Not ||
                       instruction.opcode == WirOpcode.Abs) {
                if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("integer unary operation has an invalid WIR shape");
                }

                let source: A64Register = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let destination: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, false);
                let width: Int = a64_scalar_width(ref program, instruction.type_id);
                let encoded: Bool = false;
                if (instruction.opcode == WirOpcode.Negate) {
                    encoded = a64_sub_register(ref output, destination, A64Register.ZR, source, width == 64);
                } else if (instruction.opcode == WirOpcode.Not && instruction.type_id == program.bool_type) {
                    let one: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, false);
                    encoded = one != A64Register.None &&
                              a64_mov_immediate(ref output, one, 1UL, false) &&
                              a64_logical_register(ref output, destination, source, one, 2, false);
                } else if (instruction.opcode == WirOpcode.Not) {
                    encoded = a64_invert_register(ref output, destination, source, width == 64);
                } else {
                    let negative: A64Register = a64_alloc_register(ref program, stack.homes, ref values, ref output, false);
                    encoded = negative != A64Register.None &&
                              a64_compare_zero(ref output, source, width == 64) &&
                              a64_sub_register(ref output, negative, A64Register.ZR, source, width == 64) &&
                              a64_select_condition(ref output, destination, negative, source, A64Condition.Minus, width == 64);
                }
                if (source == A64Register.None || destination == A64Register.None || width == 0 || !encoded ||
                    !a64_save_home(ref values, ref output, stack.homes, instruction.result, destination, width)) {
                    return a64_lowering_error("cannot encode AArch64 integer unary operation");
                }
            } else if (instruction.opcode == WirOpcode.NullCheck) {
                if (instruction.operands.length() != 1 || instruction.result != NO_WIR_VALUE) {
                    return a64_lowering_error("AArch64 null check has an invalid WIR shape");
                }

                let checked_id: WirValueID = instruction.operands[0];
                let checked_type: WirTypeID = program.arena.values[wir_id_index(UInt32(checked_id))].type_id;
                let ptr type: WirType = ref program.arena.types[wir_id_index(UInt32(checked_type))];
                let checked: A64Register = a64_materialize(ref program, checked_id, stack.homes, ref values, ref output);
                if (type.kind != WirTypeKind.Pointer || checked == A64Register.None ||
                    !a64_compare_zero(ref output, checked, true) ||
                    !a64_conditional_branch(ref output, 12, A64Condition.NotEqual) ||
                    !a64_branch_symbol(ref output, "__wl_fail_null", true)) {
                    return a64_lowering_error("cannot encode an AArch64 null check");
                }

                a64_trap(ref output);
            } else if (instruction.opcode == WirOpcode.BoundsCheck) {
                if (instruction.operands.length() != 2 || instruction.result != NO_WIR_VALUE) {
                    return a64_lowering_error("AArch64 bounds check has an invalid WIR shape");
                }

                let index_id: WirValueID = instruction.operands[0];
                let limit_id: WirValueID = instruction.operands[1];
                let index_value: WirValue = program.arena.values[wir_id_index(UInt32(index_id))];
                let limit_value: WirValue = program.arena.values[wir_id_index(UInt32(limit_id))];
                let index_type: WirType = program.arena.types[wir_id_index(UInt32(index_value.type_id))];
                let width: Int = a64_scalar_width(ref program, index_value.type_id);
                let index: A64Register = a64_materialize(ref program, index_id, stack.homes, ref values, ref output);
                let limit: A64Register = a64_materialize(ref program, limit_id, stack.homes, ref values, ref output);
                if (index_value.type_id != limit_value.type_id || width == 0 ||
                    (index_type.kind != WirTypeKind.SignedInt && index_type.kind != WirTypeKind.UnsignedInt) ||
                    index == A64Register.None || limit == A64Register.None ||
                    !a64_compare_register(ref output, index, limit, width == 64) ||
                    !a64_conditional_branch(ref output, 12, A64Condition.CarryClear) ||
                    !a64_branch_symbol(ref output, "__wl_fail_bounds", true)) {
                    return a64_lowering_error("cannot encode an AArch64 bounds check");
                }

                a64_trap(ref output);
            } else if (instruction.opcode == WirOpcode.Retain || instruction.opcode == WirOpcode.Release) {
                if (instruction.operands.length() != 1 || instruction.result != NO_WIR_VALUE) {
                    return a64_lowering_error("AArch64 ownership operation has an invalid WIR shape");
                }

                if (!a64_flush_registers(ref program, stack.homes, ref values, ref output)) {
                    return a64_lowering_error("cannot spill AArch64 values before an ownership call");
                }
                let object: A64Register = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let target: String = "__wl_retain";
                if (instruction.opcode == WirOpcode.Release) {
                    target = "__wl_release";
                }
                if (object == A64Register.None ||
                    (object != A64Register.X0 && !a64_mov_register(ref output, A64Register.X0, object, true)) ||
                    !a64_branch_symbol(ref output, target, true)) {
                    return a64_lowering_error("cannot encode an AArch64 ownership call");
                }
                a64_clear_bindings(ref values);
            } else if (instruction.opcode == WirOpcode.Call) {
                if (instruction.operands.length() == 0 || instruction.call_type == NO_WIR_TYPE) {
                    return a64_lowering_error("AArch64 call has no target or function type");
                }

                let callee_id: WirValueID = instruction.operands[0];
                let callee: WirValue = program.arena.values[wir_id_index(UInt32(callee_id))];
                let direct: Bool = callee.kind == WirValueKind.Function;
                let callee_name: String = "";
                if (direct) {
                    let function_index: Int = wir_id_index(callee.owner);
                    if (function_index < 0 || function_index >= program.arena.functions.length()) {
                        return a64_lowering_error("direct call target is outside the WIR function arena");
                    }
                    callee_name = program.arena.functions[function_index].name;
                }

                let call_type: WirType = machine_call_signature(ref program, instruction);
                if (call_type.parameters.length() != instruction.operands.length() - 1) {
                    return a64_lowering_error("AArch64 call arguments do not match the WIR function type");
                }

                if (!a64_flush_registers(ref program, stack.homes, ref values, ref output)) {
                    return a64_lowering_error("cannot spill live AArch64 values before a call");
                }

                if (instruction.result != NO_WIR_VALUE && a64_aggregate_type(ref program, instruction.type_id)) {
                    let result_layout: WirTypeLayout = layouts[wir_id_index(UInt32(instruction.type_id))];
                    let result_home: A64StackSlot = a64_find_stack_slot(stack.homes, instruction.result);
                    let result_hfa: A64HFA = a64_hfa_type(ref program, instruction.type_id, layouts);
                    if (!result_layout.valid || result_home.value == NO_WIR_VALUE) {
                        return a64_lowering_error("AArch64 aggregate call result has no valid home");
                    }
                    if (result_layout.size > 16UL && !result_hfa.valid &&
                        !a64_stack_address(ref output, A64Register.X8, result_home.offset)) {
                        return a64_lowering_error("cannot pass the AArch64 aggregate result pointer");
                    }
                }

                let argument_state: A64ArgumentState = A64ArgumentState(integer=0, floating=0, stack=0);
                let argument_index: Int = 1;
                while (argument_index < instruction.operands.length()) {
                    // values were flushed above, each argument can reuse the scratch bank.
                    // ABI argument registers are outside that bank and keep the copies already made.
                    a64_clear_bindings(ref values);
                    let argument: WirValueID = instruction.operands[argument_index];
                    let argument_type: WirTypeID = program.arena.values[wir_id_index(UInt32(argument))].type_id;
                    let width: Int = a64_integer_width(ref program, argument_type);
                    let floating: Bool = a64_scalar_float(ref program, argument_type);
                    let location: A64ArgumentLocation = a64_argument_location(ref program, argument_type, layouts, ref argument_state);
                    if (!location.valid) {
                        return a64_lowering_error("AArch64 call argument has no valid ABI location");
                    }

                    if (a64_aggregate_type(ref program, argument_type)) {
                        let layout: WirTypeLayout = layouts[wir_id_index(UInt32(argument_type))];
                        let home: A64StackSlot = a64_find_stack_slot(stack.homes, argument);
                        let hfa: A64HFA = a64_hfa_type(ref program, argument_type, layouts);
                        let register_count: Int = a64_aggregate_register_count(layout);
                        if (!layout.valid || home.value == NO_WIR_VALUE) {
                            return a64_lowering_error("AArch64 aggregate call argument has no valid home");
                        }

                        if (location.on_stack) {
                            let stored: Bool = false;
                            if (location.indirect) {
                                if (!a64_spill_register(ref program, stack.homes, ref values, ref output, A64Register.X9)) {
                                    return a64_lowering_error("cannot release the AArch64 aggregate address register");
                                }
                                stored = a64_stack_address(ref output, A64Register.X9, home.offset) &&
                                         a64_store_integer_at(ref output, A64Register.X9, A64Register.SP, location.offset, 64);
                            } else {
                                if (!a64_spill_register(ref program, stack.homes, ref values, ref output, A64Register.X9)) {
                                    return a64_lowering_error("cannot release the AArch64 aggregate copy register");
                                }
                                stored = a64_copy_memory(
                                    ref output,
                                    A64Register.SP,
                                    location.offset,
                                    A64Register.SP,
                                    home.offset,
                                    Int(layout.size),
                                    A64Register.X9
                                );
                            }
                            if (!stored) {
                                return a64_lowering_error("cannot store an AArch64 stack aggregate argument");
                            }
                        } else if (hfa.valid) {
                            if (!a64_load_hfa_registers(ref output, home, location.first, hfa)) {
                                return a64_lowering_error("cannot load an AArch64 homogeneous float argument");
                            }
                        } else if (!location.indirect) {
                            if (!a64_load_aggregate_registers(ref output, home, location.first, register_count)) {
                                return a64_lowering_error("cannot load an AArch64 aggregate call argument");
                            }
                        } else {
                            let destination: A64Register = a64_argument_register(location.first, false);
                            if (destination == A64Register.None ||
                                !a64_stack_address(ref output, destination, home.offset)) {
                                return a64_lowering_error("cannot pass an indirect AArch64 aggregate argument");
                            }
                        }

                        argument_index++;
                        continue;
                    }

                    if (width == 128) {
                        let pair: A64RegisterPair = a64_materialize_pair(ref program, argument, stack.homes, ref values, ref output);
                        let assigned: Bool = pair.low != A64Register.None && pair.high != A64Register.None;
                        if (assigned && location.on_stack) {
                            assigned = a64_store_integer_at(ref output, pair.low, A64Register.SP, location.offset, 64) &&
                                       a64_store_integer_at(ref output, pair.high, A64Register.SP, location.offset + 8, 64);
                        } else if assigned {
                            let low: A64Register = a64_argument_register(location.first, false);
                            let high: A64Register = a64_argument_register(location.first + 1, false);
                            assigned = low != A64Register.None && high != A64Register.None &&
                                       a64_mov_register(ref output, low, pair.low, true) &&
                                       a64_mov_register(ref output, high, pair.high, true);
                        }
                        if (!assigned) {
                            return a64_lowering_error("cannot assign an AArch64 128-bit call argument");
                        }

                        argument_index++;
                        continue;
                    }

                    width = a64_scalar_width(ref program, argument_type);
                    let source: A64Register = a64_materialize_address(
                        ref program,
                        argument,
                        stack.storage,
                        stack.homes,
                        ref values,
                        ref output
                    );
                    let assigned: Bool = source != A64Register.None && width != 0;
                    if (assigned && location.on_stack) {
                        if floating {
                            assigned = a64_store_float_at(ref output, source, A64Register.SP, location.offset, width == 64);
                        } else {
                            assigned = a64_store_integer_at(ref output, source, A64Register.SP, location.offset, width);
                        }
                    } else if assigned {
                        let destination: A64Register = a64_argument_register(location.first, floating);
                        assigned = destination != A64Register.None;
                        if (assigned && source != destination && floating) {
                            assigned = a64_float_move(ref output, destination, source, width == 64);
                        } else if (assigned && source != destination) {
                            assigned = a64_mov_register(ref output, destination, source, width == 64);
                        }
                    }
                    if (!assigned) {
                        return a64_lowering_error("cannot assign AArch64 call argument " + argument_index + " for '" + callee_name + "'");
                    }
                    argument_index++;
                }

                let called: Bool = false;
                if (direct) {
                    called = a64_branch_symbol(ref output, callee_name, true);
                } else {
                    let target: A64Register = a64_materialize_address(
                        ref program,
                        callee_id,
                        stack.storage,
                        stack.homes,
                        ref values,
                        ref output
                    );
                    called = target != A64Register.None &&
                             a64_mov_register(ref output, A64Register.X16, target, true) &&
                             a64_branch_register(ref output, A64Register.X16, true);
                }
                if (!called) {
                    return a64_lowering_error("cannot encode an AArch64 call target");
                }
                a64_clear_bindings(ref values);

                if (instruction.result != NO_WIR_VALUE && a64_aggregate_type(ref program, instruction.type_id)) {
                    let result_layout: WirTypeLayout = layouts[wir_id_index(UInt32(instruction.type_id))];
                    let result_home: A64StackSlot = a64_find_stack_slot(stack.homes, instruction.result);
                    let result_hfa: A64HFA = a64_hfa_type(ref program, instruction.type_id, layouts);
                    let register_count: Int = a64_aggregate_register_count(result_layout);
                    if (result_hfa.valid &&
                        !a64_save_hfa_registers(ref output, result_home, 0, result_hfa)) {
                        return a64_lowering_error("cannot save an AArch64 homogeneous float result");
                    }
                    if (!result_hfa.valid && register_count != 0 &&
                        !a64_save_aggregate_registers(ref output, result_home, 0, register_count)) {
                        return a64_lowering_error("cannot save an AArch64 aggregate call result");
                    }

                    a64_finish_instruction(ref values, instruction);
                    instruction_index++;
                    continue;
                }

                let result_width: Int = a64_integer_width(ref program, instruction.type_id);
                if (instruction.result != NO_WIR_VALUE && result_width == 128) {
                    if (!a64_save_pair(
                        ref values,
                        ref output,
                        stack.homes,
                        instruction.result,
                        A64RegisterPair(low=A64Register.X0, high=A64Register.X1)
                    )) {
                        return a64_lowering_error("cannot bind the AArch64 128-bit call result");
                    }

                    a64_finish_instruction(ref values, instruction);
                    instruction_index++;
                    continue;
                }

                result_width = a64_scalar_width(ref program, instruction.type_id);
                let result_register: A64Register = A64Register.X0;
                if (a64_scalar_float(ref program, instruction.type_id)) { result_register = A64Register.V0; }
                if (instruction.result != NO_WIR_VALUE &&
                    (result_width == 0 || !a64_save_home(ref values, ref output, stack.homes, instruction.result, result_register, result_width))) {
                    return a64_lowering_error("cannot bind the AArch64 call result");
                }
            } else if (instruction.opcode == WirOpcode.Trap || instruction.opcode == WirOpcode.Unreachable) {
                if (instruction.operands.length() != 0 || instruction.result != NO_WIR_VALUE) {
                    return a64_lowering_error("AArch64 trap instruction has an invalid WIR shape");
                }

                a64_trap(ref output);
            } else if (instruction.opcode == WirOpcode.Jump) {
                if (instruction.operands.length() != 0 || instruction.edges.length() != 1 ||
                    !a64_write_edge(ref program, instruction.edges[0], stack, layouts, ref values, ref output)) {
                    return a64_lowering_error("cannot lower AArch64 jump arguments");
                }
                if (!carry && !a64_flush_registers(ref program, stack.homes, ref values, ref output)) {
                    return a64_lowering_error("cannot spill AArch64 jump values");
                }

                let patch: Int = output.bytes.length();
                if (!a64_branch(ref output, 0, false)) { return a64_lowering_error("cannot encode AArch64 jump"); }
                fixups.append(A64BranchFixup(offset=patch, target=instruction.edges[0].target, condition=A64Condition.Always, conditional=false));
            } else if (instruction.opcode == WirOpcode.Branch) {
                if (instruction.operands.length() != 1 || instruction.edges.length() != 2) {
                    return a64_lowering_error("branch has an invalid WIR shape");
                }

                if (!a64_flush_registers(ref program, stack.homes, ref values, ref output)) {
                    return a64_lowering_error("cannot spill AArch64 values before a branch");
                }

                let condition: A64Register = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                if (condition == A64Register.None || !a64_compare_zero(ref output, condition, false)) {
                    return a64_lowering_error("cannot materialize the AArch64 branch condition");
                }

                let false_copy: Int = output.bytes.length();
                if (!a64_conditional_branch(ref output, 0, A64Condition.Equal)) {
                    return a64_lowering_error("cannot encode AArch64 conditional branch");
                }

                if (!a64_write_edge(ref program, instruction.edges[0], stack, layouts, ref values, ref output)) {
                    return a64_lowering_error("cannot lower the true AArch64 branch arguments");
                }
                if (!a64_flush_registers(ref program, stack.homes, ref values, ref output)) {
                    return a64_lowering_error("cannot spill true AArch64 branch values");
                }
                let true_patch: Int = output.bytes.length();
                if (!a64_branch(ref output, 0, false)) { return a64_lowering_error("cannot encode AArch64 true branch"); }
                fixups.append(A64BranchFixup(offset=true_patch, target=instruction.edges[0].target, condition=A64Condition.Always, conditional=false));

                if (!a64_patch_branch(ref output, false_copy, output.bytes.length(), A64Condition.Equal, true)) {
                    return a64_lowering_error("cannot patch AArch64 branch argument path");
                }

                a64_clear_bindings(ref values);
                if (!a64_write_edge(ref program, instruction.edges[1], stack, layouts, ref values, ref output)) {
                    return a64_lowering_error("cannot lower the false AArch64 branch arguments");
                }
                if (!a64_flush_registers(ref program, stack.homes, ref values, ref output)) {
                    return a64_lowering_error("cannot spill false AArch64 branch values");
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
                    let value_type: WirTypeID = program.arena.values[wir_id_index(UInt32(value))].type_id;
                    if (a64_aggregate_type(ref program, value_type)) {
                        let layout: WirTypeLayout = layouts[wir_id_index(UInt32(value_type))];
                        let home: A64StackSlot = a64_find_stack_slot(stack.homes, value);
                        let hfa: A64HFA = a64_hfa_type(ref program, value_type, layouts);
                        let register_count: Int = a64_aggregate_register_count(layout);
                        if (!layout.valid || home.value == NO_WIR_VALUE) {
                            return a64_lowering_error("AArch64 aggregate return value has no valid home");
                        }

                        if (hfa.valid) {
                            if (!a64_load_hfa_registers(ref output, home, 0, hfa)) {
                                return a64_lowering_error("cannot load the AArch64 homogeneous float result");
                            }
                        } else if (register_count != 0) {
                            if (!a64_load_aggregate_registers(ref output, home, 0, register_count)) {
                                return a64_lowering_error("cannot load the AArch64 aggregate return registers");
                            }
                        } else {
                            let destination: A64Register = A64Register.X9;
                            let temporary: A64Register = A64Register.X10;
                            if (stack.result_pointer_offset < 0 ||
                                !a64_load_integer(
                                    ref output,
                                    destination,
                                    A64Register.SP,
                                    stack.result_pointer_offset,
                                    64
                                ) ||
                                !a64_copy_memory(
                                    ref output,
                                    destination,
                                    0,
                                    A64Register.SP,
                                    home.offset,
                                    Int(layout.size),
                                    temporary
                                )) {
                                return a64_lowering_error("cannot copy the indirect AArch64 aggregate return value");
                            }
                        }
                    } else if (a64_integer_width(ref program, value_type) == 128) {
                        let pair: A64RegisterPair = a64_materialize_pair(ref program, value, stack.homes, ref values, ref output);
                        if (pair.low == A64Register.None || pair.high == A64Register.None ||
                            !a64_mov_register(ref output, A64Register.X0, pair.low, true) ||
                            !a64_mov_register(ref output, A64Register.X1, pair.high, true)) {
                            return a64_lowering_error("cannot move the AArch64 128-bit return value");
                        }
                    } else {
                    let source: A64Register = a64_materialize(ref program, value, stack.homes, ref values, ref output);
                    let width: Int = a64_scalar_width(ref program, value_type);
                    if (source == A64Register.None || width == 0) {
                        return a64_lowering_error("cannot materialize the AArch64 return value");
                    }
                    let result_register: A64Register = A64Register.X0;
                    let floating: Bool = a64_scalar_float(ref program, program.arena.values[wir_id_index(UInt32(value))].type_id);
                    if floating { result_register = A64Register.V0; }
                    let moved: Bool = source == result_register;
                    if (!moved && floating) {
                        moved = a64_float_move(ref output, result_register, source, width == 64);
                    } else if (!moved) {
                        moved = a64_mov_register(ref output, result_register, source, width == 64);
                    }
                    if (!moved) {
                        return a64_lowering_error("cannot move the AArch64 return value");
                    }
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
                return a64_lowering_error("WIR opcode " + Int(instruction.opcode) + " is not covered by initial AArch64 lowering");
            }
            // next-use positions describe emission order. Save
            // a late definition before dead-register cleanup discards it.
            if (instruction.result != NO_WIR_VALUE &&
                a64_use_precedes_definition(ref values.uses, instruction.result, values.position)) {
                let reg: A64Register = a64_mapped_register(ref values, instruction.result);
                let binding: Int = a64_binding_index(ref values, reg);
                if (binding >= 0 && !a64_spill_binding(ref program, stack.homes, ref values, ref output, binding)) {
                    return a64_lowering_error("cannot save an AArch64 value used by an earlier block");
                }
            }

            a64_finish_instruction(ref values, instruction);
            instruction_index++;
        }
        i++;
    }

    if (!a64_patch_branches(ref output, offsets, fixups)) {
        return a64_lowering_error("cannot patch AArch64 control-flow edges");
    }

    return A64LoweringResult(bytes=output.bytes, errors=[], relocations=output.relocations);
}
