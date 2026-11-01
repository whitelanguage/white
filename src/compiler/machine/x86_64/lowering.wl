// src/compiler/machine/x86_64/lowering.wl
import * from "model.wl"
import * from "../allocator.wl"
import * from "../../wir/model.wl"
import * from "encoder.wl"
import x86_win64_frame from "unwind.wl"
import * from "allocator.wl"
import * from "memory.wl"
import * from "abi.wl"
import * from "sse.wl"
import * from "abi/sysv.wl"
import * from "../../abi/sysv.wl"
import x86_address_symbol, x86_emit_globals from "data.wl"
import * from "edges.wl"
import * from "flow.wl"
import * from "stack.wl"
import * from "types.wl"
import * from "values.wl"
import * from "wide.wl"
import machine_layout_valid from "../layout.wl"
import machine_call_signature from "../calls.wl"


func x86_lowering_error(message: String) -> X86LoweringResult {
    return X86LoweringResult(bytes=[], errors=[message], calls=[], relocations=[]);
}

func x86_lower_instruction(ref program: WirModule,
                           ref function: WirFunction,
                           ref instruction: WirInstruction, slots: Vector(X86StackSlot),
                           scratch: Vector(Int), frame_size: Int,
                           ref state: X86BlockState,
                           ref output: X86CodeBuffer,
                           ref fixups: Vector(X86BranchFixup),
                           ref calls: Vector(X86CallFixup)
                        ) -> String {
    // only an immediately preceding comparison may supply branch flags
    if (instruction.opcode != WirOpcode.Branch) {
        state.flags_value = NO_WIR_VALUE;
        state.flags_opcode = X86Opcode.Invalid;
    }
    if (instruction.opcode == WirOpcode.StackAlloc) {
        state.accumulator = NO_WIR_VALUE;
        return "";
    }

    if (instruction.opcode == WirOpcode.NullCheck) {
        if (instruction.operands.length() != 1 || instruction.result != NO_WIR_VALUE) {
            return "null check requires one operand and no result";
        }
        let ptr value: WirValue = ref program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
        let ptr type: WirType = ref program.arena.types[wir_id_index(UInt32(value.type_id))];
        if (type.kind != WirTypeKind.Pointer) {
            return "null check requires a pointer operand";
        }
        let checked: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
        if (checked.message.length() != 0) { return checked.message; }
        x86_test_register_width(ref output, checked.register, checked.register, true);
        let valid: Int = x86_jump_if_rel32(ref output, X86Opcode.Jne);
        x86_runtime_failure(state.null_function, ref output, ref calls);
        if (!x86_patch_i32(ref output, valid, output.bytes.length() - (valid + 4))) {
            return "cannot resolve null check";
        }
        state.accumulator = NO_WIR_VALUE;
        return "";
    }

    if (instruction.opcode == WirOpcode.BoundsCheck) {
        if (instruction.operands.length() != 2 || instruction.result != NO_WIR_VALUE) {
            return "bounds check requires an index, a limit and no result";
        }
        let index_value: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
        let limit_value: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[1]))];
        let ptr type: WirType = ref program.arena.types[wir_id_index(UInt32(index_value.type_id))];
        let size: Int = x86_scalar_size(ref program, index_value.type_id);
        if (index_value.type_id != limit_value.type_id || size == 0 ||
            (type.kind != WirTypeKind.SignedInt && type.kind != WirTypeKind.UnsignedInt)) {
            return "bounds check requires matching integer operands";
        }
        let index: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
        if (index.message.length() != 0) { return index.message; }
        let limit: X86RegisterResult = x86_materialize_register_except(ref program, ref function, instruction.operands[1], slots, ref state, index.register, ref output);
        if (limit.message.length() != 0) { return limit.message; }
        let negative: Int = -1;
        if (type.kind == WirTypeKind.SignedInt) {
            x86_test_register_width(ref output, index.register, index.register, size == 8);
            negative = x86_jump_if_rel32(ref output, X86Opcode.Jl);
        }
        if (size == 8) {
            x86_cmp_register64(ref output, index.register, limit.register);
        }
        else {
            x86_cmp_register32(ref output, index.register, limit.register);
        }
        let valid_condition: X86Opcode = X86Opcode.Jb;
        if (type.kind == WirTypeKind.SignedInt) { valid_condition = X86Opcode.Jl; }
        let valid: Int = x86_jump_if_rel32(ref output, valid_condition);
        let trap: Int = output.bytes.length();
        x86_runtime_failure(state.bounds_function, ref output, ref calls);
        let continuation: Int = output.bytes.length();
        if ((negative >= 0 && !x86_patch_i32(ref output, negative, trap - (negative + 4))) ||
            !x86_patch_i32(ref output, valid, continuation - (valid + 4))) {
            return "cannot resolve bounds check";
        }
        state.accumulator = NO_WIR_VALUE;
        return "";
    }

    if (instruction.opcode == WirOpcode.AtomicLoad) {
        if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
            return "atomic load requires one address and one result";
        }
        let size: Int = x86_scalar_size(ref program, instruction.type_id);
        if (size == 0 || x86_scalar_float(ref program, instruction.type_id)) {
            return "the x86_64 backend supports atomic integer loads up to 64 bits";
        }
        let address: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
        if (address.message.length() != 0) { return address.message; }
        let choice: X86RegisterChoice = x86_choose_register_except(ref program, ref state.registers, state.position, address.register);
        let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
        if (prepare_error.length() != 0) { return prepare_error; }
        if (!x86_load_scalar(ref output, choice.register, address.register, 0, size, x86_scalar_signed(ref program, instruction.type_id))) {
            return "cannot encode atomic load";
        }
        x86_bind_register(ref state.registers, choice.register, instruction.result);
        state.accumulator = instruction.result;
        return "";
    }

    if (instruction.opcode == WirOpcode.AtomicStore) {
        if (instruction.operands.length() != 2 || instruction.result != NO_WIR_VALUE) {
            return "atomic store requires one value, one address and no result";
        }
        let value_id: WirValueID = instruction.operands[0];
        let ptr value: WirValue = ref program.arena.values[wir_id_index(UInt32(value_id))];
        let size: Int = x86_scalar_size(ref program, value.type_id);
        if (size == 0 || x86_scalar_float(ref program, value.type_id)) {
            return "the x86_64 backend supports atomic integer stores up to 64 bits";
        }
        let stored: X86RegisterResult = x86_materialize_register(ref program, ref function, value_id, slots, ref state, ref output);
        if (stored.message.length() != 0) { return stored.message; }
        let address: X86RegisterResult = x86_materialize_register_except(ref program, ref function, instruction.operands[1], slots, ref state, stored.register, ref output);
        if (address.message.length() != 0) { return address.message; }
        if (instruction.memory_order == WirMemoryOrder.SequentiallyConsistent) {
            let choice: X86RegisterChoice = x86_choose_register_avoiding(ref program, ref state.registers, state.position, stored.register, address.register);
            let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
            x86_move_scalar(ref output, choice.register, stored.register, size);
            if (!x86_atomic_exchange(ref output, address.register, choice.register, size)) {
                return "cannot encode sequentially consistent atomic store";
            }
            x86_clear_register(ref state.registers, choice.register);
        } else if (!x86_store_scalar(ref output, stored.register, address.register, 0, size)) {
            return "cannot encode atomic store";
        }
        state.accumulator = NO_WIR_VALUE;
        return "";
    }

    if (instruction.opcode == WirOpcode.AtomicRmw) {
        if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
            return "atomic RMW requires one address, one value and one result";
        }
        let value_id: WirValueID = instruction.operands[1];
        let ptr value: WirValue = ref program.arena.values[wir_id_index(UInt32(value_id))];
        let size: Int = x86_scalar_size(ref program, value.type_id);
        if (size == 0 || x86_scalar_float(ref program, value.type_id)) {
            return "the x86_64 backend supports atomic integer RMW operations up to 64 bits";
        }
        if (instruction.atomic_op == WirAtomicOp.BitAnd || instruction.atomic_op == WirAtomicOp.BitOr || instruction.atomic_op == WirAtomicOp.BitXor) {
            let save_error: String = x86_save_live_registers(ref program, slots, instruction.operands, ref state, ref output);
            if (save_error.length() != 0) { return save_error; }
            let address: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
            if (address.message.length() != 0) { return address.message; }
            let source: X86RegisterResult = x86_materialize_register_except(ref program, ref function, value_id, slots, ref state, address.register, ref output);
            if (source.message.length() != 0) { return source.message; }
            let clobbers: UInt64 = x86_register_clobber(X86Register.RAX) |
                                     x86_register_clobber(X86Register.RCX) |
                                     x86_register_clobber(X86Register.RDX) |
                                     x86_register_clobber(X86Register.R8);
            let prepare_error: String = x86_prepare_clobbers(ref program, ref state, clobbers, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
            x86_mov_register64(ref output, X86Register.RDX, address.register);
            x86_move_scalar(ref output, X86Register.R8, source.register, size);
            if (!x86_load_scalar(ref output, X86Register.RAX, X86Register.RDX, 0, size, x86_scalar_signed(ref program, value.type_id))) {
                return "cannot load an atomic RMW operand";
            }
            let retry: Int = output.bytes.length();
            x86_move_scalar(ref output, X86Register.RCX, X86Register.RAX, size);
            if (instruction.atomic_op == WirAtomicOp.BitAnd) {
                x86_and_register_width(ref output, X86Register.RCX, X86Register.R8, size == 8);
            }
            else if (instruction.atomic_op == WirAtomicOp.BitOr) {
                x86_or_register_width(ref output, X86Register.RCX, X86Register.R8, size == 8);
            }
            else {
                x86_xor_register_width(ref output, X86Register.RCX, X86Register.R8, size == 8);
            }
            if (!x86_atomic_compare_exchange(ref output, X86Register.RDX, X86Register.RCX, size)) {
                return "cannot encode atomic compare-exchange loop";
            }
            let failed: Int = x86_jump_if_rel32(ref output, X86Opcode.Jne);
            if (!x86_patch_i32(ref output, failed, retry - (failed + 4))) {
                return "cannot resolve atomic compare-exchange loop";
            }
            x86_normalize_scalar(ref output, X86Register.RAX, size, x86_scalar_signed(ref program, value.type_id));
            x86_bind_register(ref state.registers, X86Register.RAX, instruction.result);
            state.accumulator = instruction.result;
            return "";
        }
        let address: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
        if (address.message.length() != 0) { return address.message; }
        let source: X86RegisterResult = x86_materialize_register_except(ref program, ref function, value_id, slots, ref state, address.register, ref output);
        if (source.message.length() != 0) { return source.message; }
        let destination: X86Register = source.register;
        if (x86_next_use(ref state.registers.uses, value_id, state.position) != X86_NO_NEXT_USE) {
            let choice: X86RegisterChoice = x86_choose_register_avoiding(ref program, ref state.registers, state.position, source.register, address.register);
            let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
            destination = choice.register;
            x86_move_scalar(ref output, destination, source.register, size);
        }
        if (instruction.atomic_op == WirAtomicOp.Subtract) {
            x86_unary_register(ref output, destination, 3, size == 8);
        }
        let encoded: Bool = false;
        if (instruction.atomic_op == WirAtomicOp.Exchange) {
            encoded = x86_atomic_exchange(ref output, address.register, destination, size);
        }
        else {
            encoded = x86_atomic_xadd(ref output, address.register, destination, size);
        }
        if (!encoded) {
            return "cannot encode atomic RMW operation";
        }
        x86_normalize_scalar(ref output, destination, size, x86_scalar_signed(ref program, value.type_id));
        x86_bind_register(ref state.registers, destination, instruction.result);
        state.accumulator = instruction.result;
        return "";
    }

    if (instruction.opcode == WirOpcode.Retain || instruction.opcode == WirOpcode.Release) {
        if (instruction.operands.length() != 1 || instruction.result != NO_WIR_VALUE) {
            return "ownership operation requires one pointer and no result";
        }
        let target: WirFuncID = state.retain_function;
        if (instruction.opcode == WirOpcode.Release) { target = state.release_function; }
        if (target == NO_WIR_FUNC) {
            return "ownership runtime function is missing";
        }
        let save_error: String = x86_save_live_registers(ref program, slots, instruction.operands, ref state, ref output);
        if (save_error.length() != 0) { return save_error; }
        let object: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
        if (object.message.length() != 0) { return object.message; }
        let object_arg: X86Register = x86_argument_register(0, false);
        if (object.register != object_arg) {
            x86_mov_register64(ref output, object_arg, object.register);
        }
        calls.append(X86CallFixup(offset=x86_call_rel32(ref output), target=target));
        x86_reset_registers(ref state.registers);
        state.accumulator = NO_WIR_VALUE;
        return "";
    }

    if (x86_wide_integer(ref program, instruction.type_id) &&
        (instruction.opcode == WirOpcode.Add || instruction.opcode == WirOpcode.Subtract || instruction.opcode == WirOpcode.Multiply ||
         instruction.opcode == WirOpcode.BitAnd || instruction.opcode == WirOpcode.BitOr || instruction.opcode == WirOpcode.BitXor)) {
        if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
            return "128-bit integer operation requires two operands and a result";
        }
        let reuse_left: Bool = x86_can_reuse_wide_result(ref state, instruction.operands[0]);
        let prepare_error = x86_prepare_wide_scratch(ref program, ref state, ref output, reuse_left);
        if (prepare_error.length() != 0) { return prepare_error; }
        let load_error = "";
        if (!reuse_left) {
            load_error = x86_load_wide_half(ref program, instruction.operands[0], false, X86Register.RAX, ref state, ref output);
            if (load_error.length() == 0) {
                load_error = x86_load_wide_half(ref program, instruction.operands[0], true, X86Register.R10, ref state, ref output);
            }
        }
        if (load_error.length() == 0) {
            load_error = x86_load_wide_half(ref program, instruction.operands[1], false, X86Register.R11, ref state, ref output);
        }
        if (load_error.length() == 0) {
            load_error = x86_load_wide_half(ref program, instruction.operands[1], true, X86Register.RCX, ref state, ref output);
        }
        if (load_error.length() != 0) { return load_error; }
        if (instruction.opcode == WirOpcode.Add) {
            x86_add_register64(ref output, X86Register.RAX, X86Register.R11);
            x86_adc_register64(ref output, X86Register.R10, X86Register.RCX);
        } else if (instruction.opcode == WirOpcode.Subtract) {
            x86_sub_register64(ref output, X86Register.RAX, X86Register.R11);
            x86_sbb_register64(ref output, X86Register.R10, X86Register.RCX);
        } else if (instruction.opcode == WirOpcode.Multiply) {
            x86_imul_register64(ref output, X86Register.R10, X86Register.R11);
            x86_imul_register64(ref output, X86Register.RCX, X86Register.RAX);
            x86_mul_register64(ref output, X86Register.R11);
            x86_add_register64(ref output, X86Register.RDX, X86Register.R10);
            x86_add_register64(ref output, X86Register.RDX, X86Register.RCX);
            x86_mov_register64(ref output, X86Register.R10, X86Register.RDX);
        } else if (instruction.opcode == WirOpcode.BitAnd) {
            x86_and_register_width(ref output, X86Register.RAX, X86Register.R11, true);
            x86_and_register_width(ref output, X86Register.R10, X86Register.RCX, true);
        } else if (instruction.opcode == WirOpcode.BitOr) {
            x86_or_register_width(ref output, X86Register.RAX, X86Register.R11, true);
            x86_or_register_width(ref output, X86Register.R10, X86Register.RCX, true);
        } else {
            x86_xor_register_width(ref output, X86Register.RAX, X86Register.R11, true);
            x86_xor_register_width(ref output, X86Register.R10, X86Register.RCX, true);
        }
        if (!x86_store_wide_pair(instruction.result, X86Register.RAX, X86Register.R10, ref state, ref output)) {
            return "128-bit integer result has no storage";
        }
        state.accumulator = NO_WIR_VALUE;
        return "";
    }

    if (x86_wide_integer(ref program, instruction.type_id) &&
        (instruction.opcode == WirOpcode.Negate || instruction.opcode == WirOpcode.Not || instruction.opcode == WirOpcode.Abs)) {
        if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
            return "128-bit unary operation requires one operand and a result";
        }
        let reuse_source: Bool = x86_can_reuse_wide_result(ref state, instruction.operands[0]);
        let prepare_error = x86_prepare_wide_scratch(ref program, ref state, ref output, reuse_source);
        if (prepare_error.length() != 0) { return prepare_error; }
        let load_error = "";
        if (!reuse_source) {
            load_error = x86_load_wide_half(ref program, instruction.operands[0], false, X86Register.RAX, ref state, ref output);
            if (load_error.length() == 0) {
                load_error = x86_load_wide_half(ref program, instruction.operands[0], true, X86Register.R10, ref state, ref output);
            }
        }
        if (load_error.length() != 0) { return load_error; }
        if (instruction.opcode == WirOpcode.Abs) {
            // the sign comes from the high half, MIN retains its two's-complement bits
            x86_mov_register64(ref output, X86Register.R11, X86Register.R10);
            x86_shift_register_imm8(ref output, X86Register.R11, Byte(63), 7, true);
            x86_apply_wide_sign(ref output, X86Register.RAX, X86Register.R10, X86Register.R11);
        } else {
            x86_unary_register(ref output, X86Register.RAX, 2, true);
            x86_unary_register(ref output, X86Register.R10, 2, true);
            if (instruction.opcode == WirOpcode.Negate) {
                x86_mov_register_imm32(ref output, X86Register.R11, 1U);
                x86_add_register64(ref output, X86Register.RAX, X86Register.R11);
                x86_mov_register_imm32(ref output, X86Register.R11, 0U);
                x86_adc_register64(ref output, X86Register.R10, X86Register.R11);
            }
        }
        if (!x86_store_wide_pair(instruction.result, X86Register.RAX, X86Register.R10, ref state, ref output)) {
            return "128-bit unary result has no storage";
        }
        state.accumulator = NO_WIR_VALUE;
        return "";
    }

    if (x86_wide_integer(ref program, instruction.type_id) &&
        (instruction.opcode == WirOpcode.ShiftLeft || instruction.opcode == WirOpcode.SignedShiftRight || instruction.opcode == WirOpcode.UnsignedShiftRight)) {
        if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
            return "128-bit shift requires two operands and a result";
        }
        let reuse_source: Bool = x86_can_reuse_wide_result(ref state, instruction.operands[0]);
        let prepare_error = x86_prepare_wide_scratch(ref program, ref state, ref output, reuse_source);
        if (prepare_error.length() != 0) { return prepare_error; }
        let load_error = "";
        if (!reuse_source) {
            load_error = x86_load_wide_half(ref program, instruction.operands[0], false, X86Register.RAX, ref state, ref output);
            if (load_error.length() == 0) {
                load_error = x86_load_wide_half(ref program, instruction.operands[0], true, X86Register.R10, ref state, ref output);
            }
        }
        if (load_error.length() != 0) { return load_error; }
        let amount: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[1]))];
        if (amount.kind == WirValueKind.Integer) {
            x86_shift_wide_immediate(ref output, instruction.opcode, Int(amount.integer & UInt128(127U)));
        } else {
            load_error = x86_load_wide_half(ref program, instruction.operands[1], false, X86Register.RCX, ref state, ref output);
            if (load_error.length() != 0) { return load_error; }
            if (!x86_shift_wide_variable(ref output, instruction.opcode)) {
                return "cannot encode 128-bit variable shift";
            }
        }
        if (!x86_store_wide_pair(instruction.result, X86Register.RAX, X86Register.R10, ref state, ref output)) {
            return "128-bit shift result has no storage";
        }
        state.accumulator = NO_WIR_VALUE;
        return "";
    }

    if (x86_comparison_opcode(instruction.opcode) != X86Opcode.Invalid && instruction.operands.length() == 2 &&
        x86_wide_integer(ref program, program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id)) {
        if (instruction.result == NO_WIR_VALUE || instruction.type_id != program.bool_type) {
            return "128-bit comparison requires a Bool result";
        }
        let prepare_error = x86_prepare_wide_scratch(ref program, ref state, ref output);
        if (prepare_error.length() != 0) { return prepare_error; }
        let load_error = x86_load_wide_half(ref program, instruction.operands[0], false, X86Register.RAX, ref state, ref output);
        if (load_error.length() == 0) {
            load_error = x86_load_wide_half(ref program, instruction.operands[0], true, X86Register.R10, ref state, ref output);
        }
        if (load_error.length() == 0) {
            load_error = x86_load_wide_half(ref program, instruction.operands[1], false, X86Register.R11, ref state, ref output);
        }
        if (load_error.length() == 0) {
            load_error = x86_load_wide_half(ref program, instruction.operands[1], true, X86Register.RCX, ref state, ref output);
        }
        if (load_error.length() != 0) { return load_error; }
        if (instruction.opcode == WirOpcode.Equal || instruction.opcode == WirOpcode.NotEqual) {
            let condition: X86Opcode = X86Opcode.Je;
            if (instruction.opcode == WirOpcode.NotEqual) { condition = X86Opcode.Jne; }
            x86_cmp_register64(ref output, X86Register.RAX, X86Register.R11);
            x86_set_condition_register(ref output, X86Register.RAX, condition);
            x86_cmp_register64(ref output, X86Register.R10, X86Register.RCX);
            x86_set_condition_register(ref output, X86Register.R11, condition);
            if (instruction.opcode == WirOpcode.Equal) {
                x86_and_register_width(ref output, X86Register.RAX, X86Register.R11, false);
            }
            else {
                x86_or_register_width(ref output, X86Register.RAX, X86Register.R11, false);
            }
        } else {
            let high_condition: X86Opcode = x86_wide_high_comparison(instruction.opcode);
            let low_condition: X86Opcode = x86_wide_low_comparison(instruction.opcode);
            x86_cmp_register64(ref output, X86Register.RAX, X86Register.R11);
            x86_set_condition_register(ref output, X86Register.RAX, low_condition);
            x86_cmp_register64(ref output, X86Register.R10, X86Register.RCX);
            x86_set_condition_register(ref output, X86Register.R11, high_condition);
            x86_set_condition_register(ref output, X86Register.RCX, X86Opcode.Je);
            x86_and_register_width(ref output, X86Register.RAX, X86Register.RCX, false);
            x86_or_register_width(ref output, X86Register.RAX, X86Register.R11, false);
        }
        x86_bind_register(ref state.registers, X86Register.RAX, instruction.result);
        state.accumulator = instruction.result;
        return "";
    }

    if (x86_wide_integer(ref program, instruction.type_id) &&
        (instruction.opcode == WirOpcode.SignedDivide || instruction.opcode == WirOpcode.UnsignedDivide ||
         instruction.opcode == WirOpcode.SignedRemainder || instruction.opcode == WirOpcode.UnsignedRemainder)) {
        if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
            return "128-bit division requires two operands and a result";
        }
        let prepare_error = x86_prepare_wide_scratch(ref program, ref state, ref output);
        if (prepare_error.length() != 0) { return prepare_error; }
        let load_error = x86_load_wide_half(ref program, instruction.operands[0], false, X86Register.RAX, ref state, ref output);
        if (load_error.length() == 0) {
            load_error = x86_load_wide_half(ref program, instruction.operands[0], true, X86Register.R10, ref state, ref output);
        }
        if (load_error.length() == 0) {
            load_error = x86_load_wide_half(ref program, instruction.operands[1], false, X86Register.R11, ref state, ref output);
        }
        if (load_error.length() == 0) {
            load_error = x86_load_wide_half(ref program, instruction.operands[1], true, X86Register.R9, ref state, ref output);
        }
        if (load_error.length() != 0) { return load_error; }

        let signed: Bool = instruction.opcode == WirOpcode.SignedDivide || instruction.opcode == WirOpcode.SignedRemainder;
        let remainder: Bool = instruction.opcode == WirOpcode.SignedRemainder || instruction.opcode == WirOpcode.UnsignedRemainder;
        if signed {
            x86_mov_register64(ref output, X86Register.RDX, X86Register.R10);
            x86_shift_register_imm8(ref output, X86Register.RDX, Byte(63), 7, true);
            x86_apply_wide_sign(ref output, X86Register.RAX, X86Register.R10, X86Register.RDX);
            x86_mov_register64(ref output, X86Register.R8, X86Register.R9);
            x86_shift_register_imm8(ref output, X86Register.R8, Byte(63), 7, true);
            x86_apply_wide_sign(ref output, X86Register.R11, X86Register.R9, X86Register.R8);
        }
        if (!x86_divide_wide_unsigned(ref output)) {
            return "cannot encode 128-bit division";
        }

        if signed {
            load_error = x86_load_wide_half(ref program, instruction.operands[0], true, X86Register.R11, ref state, ref output);
            if (load_error.length() == 0) {
                load_error = x86_load_wide_half(ref program, instruction.operands[1], true, X86Register.RCX, ref state, ref output);
            }
            if (load_error.length() != 0) { return load_error; }
            x86_xor_register_width(ref output, X86Register.R11, X86Register.RCX, true);
            x86_shift_register_imm8(ref output, X86Register.R11, Byte(63), 7, true);
            x86_test_register_width(ref output, X86Register.R11, X86Register.R11, true);
            let same_sign: Int = x86_jump_if_rel32(ref output, X86Opcode.Je);
            if (!remainder) {
                x86_apply_wide_sign(ref output, X86Register.RAX, X86Register.R10, X86Register.R11);
            }
            let sign_done: Int = x86_jump_rel32(ref output);
            if (!x86_patch_i32(ref output, same_sign, output.bytes.length() - (same_sign + 4))) {
                return "cannot resolve signed 128-bit division";
            }
            // MIN / -1 must fault like the native signed divide instruction
            x86_test_register_width(ref output, X86Register.R10, X86Register.R10, true);
            let in_range: Int = x86_jump_if_rel32(ref output, X86Opcode.Jge);
            x86_mov_register_imm32(ref output, X86Register.R11, 0U);
            x86_div_register_width(ref output, X86Register.R11, true, false);
            if (!x86_patch_i32(ref output, in_range, output.bytes.length() - (in_range + 4)) ||
                !x86_patch_i32(ref output, sign_done, output.bytes.length() - (sign_done + 4))) {
                return "cannot resolve signed 128-bit division";
            }
        }

        if remainder {
            x86_mov_register64(ref output, X86Register.RAX, X86Register.RDX);
            x86_mov_register64(ref output, X86Register.R10, X86Register.R8);
            if signed {
                load_error = x86_load_wide_half(ref program, instruction.operands[0], true, X86Register.R11, ref state, ref output);
                if (load_error.length() != 0) { return load_error; }
                x86_shift_register_imm8(ref output, X86Register.R11, Byte(63), 7, true);
                x86_apply_wide_sign(ref output, X86Register.RAX, X86Register.R10, X86Register.R11);
            }
        }
        if (!x86_store_wide_pair(instruction.result, X86Register.RAX, X86Register.R10, ref state, ref output)) {
            return "128-bit division result has no storage";
        }
        state.accumulator = NO_WIR_VALUE;
        return "";
    }

    if (instruction.opcode == WirOpcode.StructValue || instruction.opcode == WirOpcode.ArrayValue) {
        let ptr type: WirType = ref program.arena.types[wir_id_index(UInt32(instruction.type_id))];
        let layout: WirTypeLayout = state.layouts[wir_id_index(UInt32(instruction.type_id))];
        let home = x86_stack_offset(ref state.stack, instruction.result);
        let count = type.fields.length();
        if (type.kind == WirTypeKind.Array) {
            if (type.length > UIntSize(2147483647U)) {
                return "array constructor exceeds the machine operand limit";
            }
            count = Int(type.length);
        }
        if (!layout.valid || home == 0 || instruction.operands.length() > count ||
            (instruction.opcode == WirOpcode.StructValue && type.kind != WirTypeKind.Struct) ||
            (instruction.opcode == WirOpcode.ArrayValue && type.kind != WirTypeKind.Array)) {
            return "aggregate constructor has an invalid layout or operand count";
        }
        let temporary: X86RegisterChoice = x86_choose_register(ref program, ref state.registers, state.position);
        let prepare_error = x86_prepare_memory_clobbers(ref program, ref state, Int(layout.size), temporary.register, ref output);
        if (prepare_error.length() != 0) { return prepare_error; }
        // initialize padding too, so snapshots do not copy uninitialized stack bytes
        if (!x86_zero_memory(ref output, X86Register.RBP, home, Int(layout.size), temporary.register)) {
            return "cannot initialize aggregate storage";
        }
        let i = 0;
        let stride = 0;
        if (type.kind == WirTypeKind.Array) {
            stride = Int(state.layouts[wir_id_index(UInt32(type.element))].size);
        }
        while (i < instruction.operands.length()) {
            let offset: Int = i * stride;
            if (type.kind == WirTypeKind.Struct) { offset = Int(layout.field_offsets[i]); }
            let operand: WirValueID = instruction.operands[i];
            let message = x86_store_value(ref program, ref function, operand, X86Register.RBP, home + offset, slots, ref state, ref output);
            if (message.length() != 0) { return message; }
            let repeated: Bool = false;
            let next: Int = i + 1;
            while (next < instruction.operands.length()) {
                if (instruction.operands[next] == operand) {
                    repeated = true;
                    break;
                }
                next++;
            }
            if (!repeated && x86_next_use(ref state.registers.uses, operand, state.position) == X86_NO_NEXT_USE) {
                x86_forget_register_value(ref state.registers, operand);
                x86_forget_spill_value(ref state.spills, operand);
            }
            i++;
        }
        state.accumulator = NO_WIR_VALUE;
        return "";
    }

    if (instruction.opcode == WirOpcode.Field || instruction.opcode == WirOpcode.Index) {
        if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
            return "aggregate extraction requires two operands and a result";
        }
        let aggregate: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
        let ptr type: WirType = ref program.arena.types[wir_id_index(UInt32(aggregate.type_id))];
        let index: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[1]))];
        let home = x86_stack_offset(ref state.stack, instruction.operands[0]);
        if (index.kind != WirValueKind.Integer) {
            return "aggregate extraction currently requires a constant index";
        }
        let offset = 0;
        if (instruction.opcode == WirOpcode.Field) {
            if (type.kind != WirTypeKind.Struct || index.integer >= UInt128(type.fields.length())) {
                return "aggregate field index is out of range";
            }
            offset = Int(state.layouts[wir_id_index(UInt32(aggregate.type_id))].field_offsets[Int(index.integer)]);
        } else {
            if (type.kind != WirTypeKind.Array || index.integer >= UInt128(type.length)) {
                return "aggregate element index is out of range";
            }
            offset = Int(index.integer) * Int(state.layouts[wir_id_index(UInt32(type.element))].size);
        }

        if (home == 0 && aggregate.kind == WirValueKind.Constant) {
            let ptr constant: WirConstant = ref program.arena.constants[wir_id_index(aggregate.owner)];
            if (constant.kind == WirConstKind.Aggregate && index.integer < UInt128(constant.elements.length())) {
                let member: WirValueID = constant.elements[Int(index.integer)];
                if (x86_memory_value(ref program, instruction.type_id)) {
                    let message: String = x86_store_value(
                        ref program,
                        ref function,
                        member,
                        X86Register.RBP,
                        x86_stack_offset(ref state.stack, instruction.result),
                        slots,
                        ref state,
                        ref output
                    );
                    if (message.length() != 0) { return message; }
                    state.accumulator = NO_WIR_VALUE;
                } else {
                    let value: X86RegisterResult = x86_materialize_register(ref program, ref function, member, slots, ref state, ref output);
                    if (value.message.length() != 0) { return value.message; }
                    x86_bind_register(ref state.registers, value.register, instruction.result);
                    state.accumulator = instruction.result;
                }
                return "";
            }
            if (constant.kind == WirConstKind.Zero) {
                if (x86_memory_value(ref program, instruction.type_id)) {
                    let layout: WirTypeLayout = state.layouts[wir_id_index(UInt32(instruction.type_id))];
                    let result_home: Int = x86_stack_offset(ref state.stack, instruction.result);
                    let temporary: X86RegisterChoice = x86_choose_register(ref program, ref state.registers, state.position);
                    let prepare_error: String = x86_prepare_memory_clobbers(ref program, ref state, Int(layout.size), temporary.register, ref output);
                    if (prepare_error.length() != 0) { return prepare_error; }
                    if (result_home == 0 || !x86_zero_memory(ref output, X86Register.RBP, result_home, Int(layout.size), temporary.register)) {
                        return "cannot extract a zero aggregate member";
                    }
                    state.accumulator = NO_WIR_VALUE;
                } else {
                    let choice: X86RegisterChoice = x86_choose_register_class(
                        ref program,
                        ref state.registers,
                        state.position,
                        X86Register.None,
                        x86_scalar_float(ref program, instruction.type_id)
                    );
                    let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
                    if (prepare_error.length() != 0) { return prepare_error; }
                    if (x86_is_xmm(choice.register)) {
                        let integer: X86RegisterChoice = x86_choose_register(ref program, ref state.registers, state.position);
                        prepare_error = x86_prepare_register(ref program, ref state, integer, ref output);
                        if (prepare_error.length() != 0) { return prepare_error; }
                        x86_mov_register_imm32(ref output, integer.register, 0U);
                        if (!x86_sse_bits(ref output, choice.register, integer.register, x86_scalar_size(ref program, instruction.type_id), true)) {
                            return "cannot extract a zero floating member";
                        }
                    } else {
                        x86_mov_register_imm32(ref output, choice.register, 0U);
                    }
                    x86_bind_register(ref state.registers, choice.register, instruction.result);
                    state.accumulator = instruction.result;
                }
                return "";
            }
        }
        if (home == 0) {
            return "aggregate value has no storage for extraction";
        }
        let choice: X86RegisterChoice = x86_choose_register_class(
            ref program,
            ref state.registers,
            state.position,
            X86Register.None,
            x86_scalar_float(ref program, instruction.type_id)
        );
        if (x86_memory_value(ref program, instruction.type_id)) {
            let layout: WirTypeLayout = state.layouts[wir_id_index(UInt32(instruction.type_id))];
            let prepare_error: String = x86_prepare_memory_clobbers(ref program, ref state, Int(layout.size), choice.register, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
            if (!x86_copy_memory(ref output, X86Register.RBP, x86_stack_offset(ref state.stack, instruction.result), X86Register.RBP, home + offset, Int(layout.size), choice.register)) {
                return "cannot extract aggregate member";
            }
            state.accumulator = NO_WIR_VALUE;
        } else {
            let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
            if (!x86_load_scalar(ref output, choice.register, X86Register.RBP, home + offset, x86_scalar_size(ref program, instruction.type_id), x86_scalar_signed(ref program, instruction.type_id))) { return "cannot extract scalar member"; }
            x86_bind_register(ref state.registers, choice.register, instruction.result);
            state.accumulator = instruction.result;
        }
        return "";
    }

    if (instruction.opcode == WirOpcode.Store) {
        if (instruction.operands.length() != 2) {
            return "store instruction has the wrong operand count";
        }

        let offset: Int = x86_stack_offset(ref state.stack, instruction.operands[1]);
        if (!machine_rematerializable(ref program, instruction.operands[1])) { offset = 0; }

        let stored_value: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
        if (x86_memory_value(ref program, stored_value.type_id)) {
            let address: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[1], slots, ref state, ref output);
            if (address.message.length() != 0) { return address.message; }
            let message = x86_store_value(ref program, ref function, instruction.operands[0], address.register, 0, slots, ref state, ref output);
            if (message.length() != 0) { return message; }
            state.accumulator = NO_WIR_VALUE;
            return "";
        }
        let size: Int = x86_scalar_size(ref program, stored_value.type_id);
        if (size == 0 || (offset != 0 && size > x86_stack_size(ref state.stack, instruction.operands[1]))) {
            return "store has an unsupported value or insufficient stack storage";
        }

        let stored: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
        if (stored.message.length() != 0) { return stored.message; }

        if (offset != 0) {
            x86_store_scalar(ref output, stored.register, X86Register.RBP, offset, size);
        } else {
            let address: X86RegisterResult = x86_materialize_register_except(ref program, ref function, instruction.operands[1], slots, ref state, stored.register, ref output);
            if (address.message.length() != 0) { return address.message; }

            x86_store_scalar(ref output, stored.register, address.register, 0, size);
        }
        state.accumulator = instruction.operands[0];
        return "";
    }

    if (instruction.opcode == WirOpcode.Load) {
        if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
            return "load instruction has the wrong operand count";
        }
        if (x86_memory_value(ref program, instruction.type_id)) {
            let address: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
            if (address.message.length() != 0) { return address.message; }
            let temporary: X86RegisterChoice = x86_choose_register_except(ref program, ref state.registers, state.position, address.register);
            let layout: WirTypeLayout = state.layouts[wir_id_index(UInt32(instruction.type_id))];
            let prepare_error: String = x86_prepare_memory_clobbers(ref program, ref state, Int(layout.size), temporary.register, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
            let home = x86_stack_offset(ref state.stack, instruction.result);
            if (!x86_copy_memory(ref output, X86Register.RBP, home, address.register, 0, Int(layout.size), temporary.register)) {
                return "cannot load aggregate snapshot";
            }
            state.accumulator = NO_WIR_VALUE;
            return "";
        }

        let offset: Int = x86_stack_offset(ref state.stack, instruction.operands[0]);
        if (!machine_rematerializable(ref program, instruction.operands[0])) { offset = 0; }

        let size: Int = x86_scalar_size(ref program, instruction.type_id);
        if (size == 0 || (offset != 0 && size > x86_stack_size(ref state.stack, instruction.operands[0]))) {
            return "load has an unsupported value or insufficient stack storage";
        }

        let base: X86Register = X86Register.RBP;
        if (offset == 0) {
            let address: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
            if (address.message.length() != 0) { return address.message; }

            base = address.register;
        }
        let floating: Bool = x86_scalar_float(ref program, instruction.type_id);
        let choice: X86RegisterChoice = X86RegisterChoice(register=X86Register.None, evicted=NO_WIR_VALUE);
        if (offset == 0 && !floating && x86_next_use(ref state.registers.uses, instruction.operands[0], state.position) == X86_NO_NEXT_USE &&
            x86_preferred_register(ref state.registers.uses, instruction.result) == X86Register.None) {
            // mov reg, [reg] is safe once the address has no later use
            x86_clear_register(ref state.registers, base);
            choice = X86RegisterChoice(register=base, evicted=NO_WIR_VALUE);
        } else {
            choice = x86_choose_result_register(ref program, ref state, instruction.result, base, floating);
        }

        let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
        if (prepare_error.length() != 0) { return prepare_error; }

        x86_load_scalar(ref output, choice.register, base, offset, size, x86_scalar_signed(ref program, instruction.type_id));
        x86_bind_register(ref state.registers, choice.register, instruction.result);
        state.accumulator = instruction.result;
        return "";
    }

    if (instruction.opcode == WirOpcode.SignedIntToFloat || instruction.opcode == WirOpcode.UnsignedIntToFloat ||
        instruction.opcode == WirOpcode.FloatToSignedInt || instruction.opcode == WirOpcode.FloatToUnsignedInt) {
        if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
            return "numeric conversion has the wrong operand count";
        }
        let to_float = instruction.opcode == WirOpcode.SignedIntToFloat || instruction.opcode == WirOpcode.UnsignedIntToFloat;
        let unsigned = instruction.opcode == WirOpcode.UnsignedIntToFloat || instruction.opcode == WirOpcode.FloatToUnsignedInt;
        let source_value: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
        let integer_type: WirTypeID = instruction.type_id;
        let float_type: WirTypeID = source_value.type_id;
        if to_float {
            integer_type = source_value.type_id;
            float_type = instruction.type_id;
        }
        let integer_size = x86_scalar_size(ref program, integer_type);
        let float_size = x86_scalar_size(ref program, float_type);
        let kind = program.arena.types[wir_id_index(UInt32(integer_type))].kind;
        if (integer_size == 0 || !x86_scalar_float(ref program, float_type) ||
            (unsigned && kind != WirTypeKind.UnsignedInt) || (!unsigned && kind != WirTypeKind.SignedInt)) {
            return "numeric conversion requires a scalar integer and f32 or f64";
        }
        let source: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
        if (source.message.length() != 0) { return source.message; }
        let choice: X86RegisterChoice = x86_choose_result_register(ref program, ref state, instruction.result, source.register, to_float);
        let prepare_error = x86_prepare_register(ref program, ref state, choice, ref output);
        if (prepare_error.length() != 0) { return prepare_error; }
        if (unsigned && integer_size == 8) {
            if to_float {
                let half: X86RegisterChoice = x86_choose_register_except(ref program, ref state.registers, state.position, source.register);
                prepare_error = x86_prepare_register(ref program, ref state, half, ref output);
                if (prepare_error.length() != 0) { return prepare_error; }
                let low_bit: X86RegisterChoice = x86_choose_register_avoiding(ref program, ref state.registers, state.position, source.register, half.register);
                prepare_error = x86_prepare_register(ref program, ref state, low_bit, ref output);
                if (prepare_error.length() != 0) { return prepare_error; }
                if (!x86_uint64_to_float(ref output, choice.register, source.register, half.register, low_bit.register, float_size)) {
                    return "the x86_64 encoder rejected the u64-to-float conversion";
                }
            } else {
                let temporary: X86RegisterChoice = x86_choose_register_except(ref program, ref state.registers, state.position, choice.register);
                prepare_error = x86_prepare_register(ref program, ref state, temporary, ref output);
                if (prepare_error.length() != 0) { return prepare_error; }
                let threshold: X86RegisterChoice = x86_choose_register_class(ref program, ref state.registers, state.position, source.register, true);
                prepare_error = x86_prepare_register(ref program, ref state, threshold, ref output);
                if (prepare_error.length() != 0) { return prepare_error; }
                // the upper-half path subtracts from source, preserve it before either path
                prepare_error = x86_overwrite_operand(ref program, ref state, source.register, ref output);
                if (prepare_error.length() != 0) { return prepare_error; }
                if (!x86_float_to_uint64(ref output, choice.register, source.register, threshold.register, temporary.register, float_size)) {
                    return "the x86_64 encoder rejected the float-to-u64 conversion";
                }
            }
            x86_bind_register(ref state.registers, choice.register, instruction.result);
            state.accumulator = instruction.result;
            return "";
        }
        // u32 needs a signed 64-bit conversion to retain its upper half
        let conversion_size = 4;
        if (unsigned || integer_size == 8) { conversion_size = 8; }
        if (!x86_sse_convert(ref output, choice.register, source.register, float_size, conversion_size, to_float)) {
            return "the x86_64 encoder rejected the numeric conversion";
        }
        if (!to_float) {
            x86_normalize_scalar(ref output, choice.register, integer_size, !unsigned);
        }
        x86_bind_register(ref state.registers, choice.register, instruction.result);
        state.accumulator = instruction.result;
        return "";
    }

    if (instruction.opcode == WirOpcode.FloatExtend || instruction.opcode == WirOpcode.FloatTruncate ||
        (instruction.opcode == WirOpcode.Bitcast && instruction.operands.length() == 1 &&
         (x86_scalar_float(ref program, instruction.type_id) || x86_scalar_float(ref program, program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id)))) {
        if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
            return "floating cast requires one operand and a result";
        }
        let source_id: WirValueID = instruction.operands[0];
        let source_value: WirValue = program.arena.values[wir_id_index(UInt32(source_id))];
        let source_size: Int = x86_scalar_size(ref program, source_value.type_id);
        let target_size: Int = x86_scalar_size(ref program, instruction.type_id);
        if ((source_size != 4 && source_size != 8) || (target_size != 4 && target_size != 8)) {
            return "floating casts require 32-bit or 64-bit scalar values";
        }
        let source: X86RegisterResult = x86_materialize_register(ref program, ref function, source_id, slots, ref state, ref output);
        if (source.message.length() != 0) { return source.message; }
        if (instruction.opcode == WirOpcode.Bitcast) {
            if (source_size != target_size) {
                return "bitcast operands must have equal widths";
            }
            let choice: X86RegisterChoice = x86_choose_result_register(
                ref program,
                ref state,
                instruction.result,
                X86Register.None,
                x86_scalar_float(ref program, instruction.type_id)
            );
            let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
            x86_move_scalar(ref output, choice.register, source.register, source_size);
            x86_bind_register(ref state.registers, choice.register, instruction.result);
        } else {
            if (!x86_is_xmm(source.register) || !x86_scalar_float(ref program, instruction.type_id)) {
                return "floating precision casts require floating operands";
            }
            let save_error: String = x86_overwrite_operand(ref program, ref state, source.register, ref output);
            if (save_error.length() != 0) { return save_error; }
            x86_sse_register(ref output, 90, source.register, source.register, source_size);
            x86_bind_register(ref state.registers, source.register, instruction.result);
        }
        state.accumulator = instruction.result;
        return "";
    }

    if ((instruction.opcode == WirOpcode.Truncate || instruction.opcode == WirOpcode.SignExtend || instruction.opcode == WirOpcode.ZeroExtend ||
         instruction.opcode == WirOpcode.Bitcast || instruction.opcode == WirOpcode.PointerToInt || instruction.opcode == WirOpcode.IntToPointer) &&
        instruction.operands.length() == 1 && instruction.result != NO_WIR_VALUE) {
        let source_id: WirValueID = instruction.operands[0];
        let source_value: WirValue = program.arena.values[wir_id_index(UInt32(source_id))];
        let source_wide: Bool = x86_wide_integer(ref program, source_value.type_id);
        let target_wide: Bool = x86_wide_integer(ref program, instruction.type_id);

        if (source_wide && target_wide) {
            if (instruction.opcode != WirOpcode.Bitcast) {
                return "128-bit integer casts of equal width require a bitcast";
            }
            let prepare_error: String = x86_prepare_wide_scratch(ref program, ref state, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
            let load_error: String = x86_load_wide_half(ref program, source_id, false, X86Register.RAX, ref state, ref output);
            if (load_error.length() == 0) {
                load_error = x86_load_wide_half(ref program, source_id, true, X86Register.R10, ref state, ref output);
            }
            if (load_error.length() != 0) { return load_error; }
            if (!x86_store_wide_pair(instruction.result, X86Register.RAX, X86Register.R10, ref state, ref output)) {
                return "128-bit bitcast result has no storage";
            }
            state.accumulator = NO_WIR_VALUE;
            return "";
        }

        if target_wide {
            if (instruction.opcode != WirOpcode.SignExtend && instruction.opcode != WirOpcode.ZeroExtend && instruction.opcode != WirOpcode.PointerToInt) {
                return "unsupported cast to a 128-bit integer";
            }
            let prepare_error: String = x86_prepare_wide_scratch(ref program, ref state, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
            let source: X86RegisterResult = x86_materialize_register(ref program, ref function, source_id, slots, ref state, ref output);
            if (source.message.length() != 0) { return source.message; }
            if (source.register != X86Register.RAX) {
                x86_mov_register64(ref output, X86Register.RAX, source.register);
            }
            if (instruction.opcode == WirOpcode.SignExtend) {
                let source_size: Int = x86_scalar_size(ref program, source_value.type_id);
                if (source_size < 8) {
                    x86_sign_extend32(ref output, X86Register.RAX, X86Register.RAX);
                }
                x86_mov_register64(ref output, X86Register.R10, X86Register.RAX);
                x86_shift_register_imm8(ref output, X86Register.R10, Byte(63), 7, true);
            } else {
                x86_mov_register_imm32(ref output, X86Register.R10, 0U);
            }
            if (!x86_store_wide_pair(instruction.result, X86Register.RAX, X86Register.R10, ref state, ref output)) {
                return "128-bit cast result has no storage";
            }
            state.accumulator = NO_WIR_VALUE;
            return "";
        }

        if source_wide {
            if (instruction.opcode != WirOpcode.Truncate && instruction.opcode != WirOpcode.IntToPointer) {
                return "unsupported cast from a 128-bit integer";
            }
            let target_size: Int = x86_scalar_size(ref program, instruction.type_id);
            if (target_size == 0) {
                return "128-bit integer cast has an unsupported target type";
            }
            let prepare_error: String = x86_prepare_fixed_register(ref program, ref state, X86Register.RAX, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
            let load_error: String = x86_load_wide_half(ref program, source_id, false, X86Register.RAX, ref state, ref output);
            if (load_error.length() != 0) { return load_error; }
            x86_normalize_scalar(ref output, X86Register.RAX, target_size, x86_scalar_signed(ref program, instruction.type_id));
            x86_bind_register(ref state.registers, X86Register.RAX, instruction.result);
            state.accumulator = instruction.result;
            return "";
        }
    }

    if (instruction.opcode == WirOpcode.Truncate || instruction.opcode == WirOpcode.SignExtend || instruction.opcode == WirOpcode.ZeroExtend ||
        instruction.opcode == WirOpcode.Bitcast || instruction.opcode == WirOpcode.PointerToInt || instruction.opcode == WirOpcode.IntToPointer) {
        if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
            return "cast instruction requires one operand and a result";
        }
        let source_id: WirValueID = instruction.operands[0];
        let source_value: WirValue = program.arena.values[wir_id_index(UInt32(source_id))];
        let source_size: Int = x86_scalar_size(ref program, source_value.type_id);
        let target_size: Int = x86_scalar_size(ref program, instruction.type_id);
        if (source_size == 0 || target_size == 0) {
            return "the x86_64 lowering supports integer and pointer casts up to 64 bits";
        }
        let source: X86RegisterResult = x86_materialize_register(ref program, ref function, source_id, slots, ref state, ref output);
        if (source.message.length() != 0) { return source.message; }
        let destination: X86Register = source.register;
        if (x86_next_use(ref state.registers.uses, source_id, state.position) != X86_NO_NEXT_USE) {
            let choice: X86RegisterChoice = x86_choose_result_register(ref program, ref state, instruction.result, source.register, false);
            let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
            destination = choice.register;
            x86_move_scalar(ref output, destination, source.register, source_size);
        }
        // inttoptr zero-extends the source bits, even when its declared type is signed
        if (instruction.opcode == WirOpcode.IntToPointer && source_size < 4) {
            x86_extend_register(ref output, destination, destination, source_size, false);
        } else if (instruction.opcode == WirOpcode.SignExtend && target_size == 8) {
            x86_sign_extend32(ref output, destination, destination);
        } else if (source_size < 8 && target_size == 8) {
            x86_mov_register32(ref output, destination, destination);
        }
        if (instruction.type_id == program.bool_type) {
            x86_bitwise_register_imm32(ref output, destination, 1U, 4);
        } else {
            x86_normalize_scalar(ref output, destination, target_size, x86_scalar_signed(ref program, instruction.type_id));
        }
        x86_bind_register(ref state.registers, destination, instruction.result);
        state.accumulator = instruction.result;
        return "";
    }

    if (instruction.opcode == WirOpcode.FieldAddress || instruction.opcode == WirOpcode.IndexAddress) {
        if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
            return "address instruction requires two operands and a result";
        }
        let base_value: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
        let pointer: WirType = program.arena.types[wir_id_index(UInt32(base_value.type_id))];
        if (pointer.kind != WirTypeKind.Pointer) {
            return "address instruction requires a pointer base";
        }
        let layout: WirTypeLayout = state.layouts[wir_id_index(UInt32(pointer.element))];
        if (!layout.valid) {
            return "address instruction has no valid element layout";
        }
        let base: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
        if (base.message.length() != 0) { return base.message; }
        if (instruction.opcode == WirOpcode.FieldAddress) {
            let field: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[1]))];
            if (field.kind != WirValueKind.Integer || field.integer >= UInt128(layout.field_offsets.length())) {
                return "field address has an invalid field index";
            }
            let offset: UInt64 = layout.field_offsets[Int(field.integer)];
            if (offset > 2147483647UL) {
                return "field offset exceeds the x86_64 displacement range";
            }
            let choice: X86RegisterChoice = x86_choose_result_register(ref program, ref state, instruction.result, base.register, false);
            let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
            x86_lea(ref output, choice.register, base.register, X86Register.None, 1, Int(offset));
            x86_bind_register(ref state.registers, choice.register, instruction.result);
        } else {
            let index_id: WirValueID = instruction.operands[1];
            let index_value: WirValue = program.arena.values[wir_id_index(UInt32(index_id))];
            let index_size: Int = x86_scalar_size(ref program, index_value.type_id);
            let element: WirType = program.arena.types[wir_id_index(UInt32(pointer.element))];
            if (element.kind == WirTypeKind.Array) {
                layout = state.layouts[wir_id_index(UInt32(element.element))];
            }
            if (!layout.valid || layout.size > 2147483647UL || index_size == 0) {
                return "index address has an unsupported index width or element stride";
            }
            let index: X86RegisterResult = x86_materialize_register_except(ref program, ref function, index_id, slots, ref state, base.register, ref output);
            if (index.message.length() != 0) { return index.message; }
            let choice: X86RegisterChoice = x86_choose_result_register_avoiding(ref program, ref state, instruction.result, base.register, index.register);
            let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
            if (index_size == 8) {
                x86_mov_register64(ref output, choice.register, index.register);
            }
            else if (x86_scalar_signed(ref program, index_value.type_id)) {
                x86_sign_extend32(ref output, choice.register, index.register);
            }
            else {
                x86_mov_register32(ref output, choice.register, index.register);
            }
            let scale: Int = Int(layout.size);
            if (scale != 1 && scale != 2 && scale != 4 && scale != 8) {
                x86_multiply_imm32(ref output, choice.register, UInt32(layout.size), true);
                scale = 1;
            }
            x86_lea(ref output, choice.register, base.register, choice.register, scale, 0);
            x86_bind_register(ref state.registers, choice.register, instruction.result);
        }
        state.accumulator = instruction.result;
        return "";
    }

    if (instruction.opcode == WirOpcode.FloatNegate) {
        if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE || !x86_scalar_float(ref program, instruction.type_id)) {
            return "floating negate requires one f32 or f64 operand and a result";
        }
        if (program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id != instruction.type_id) {
            return "floating negate operand and result must have the same type";
        }
        let size = x86_scalar_size(ref program, instruction.type_id);
        let source: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
        if (source.message.length() != 0) { return source.message; }
        let destination: X86RegisterChoice = x86_choose_result_register(ref program, ref state, instruction.result, source.register, true);
        let prepare_error = x86_prepare_register(ref program, ref state, destination, ref output);
        if (prepare_error.length() != 0) {
            return "floating negate destination: " + prepare_error;
        }
        let bits: X86RegisterChoice = x86_choose_register_except(ref program, ref state.registers, state.position, X86Register.None);
        prepare_error = x86_prepare_register(ref program, ref state, bits, ref output);
        if (prepare_error.length() != 0) {
            return "floating negate bits: " + prepare_error;
        }
        // flip the sign bit without floating arithmetic, keep -0 and NaN payloads intact
        x86_move_scalar(ref output, bits.register, source.register, size);
        if (size == 4) {
            x86_bitwise_register_imm32(ref output, bits.register, 2147483648U, 6);
        } else {
            let mask: X86RegisterChoice = x86_choose_register_except(ref program, ref state.registers, state.position, bits.register);
            prepare_error = x86_prepare_register(ref program, ref state, mask, ref output);
            if (prepare_error.length() != 0) {
                return "floating negate mask: " + prepare_error;
            }
            x86_mov_register_imm64(ref output, mask.register, 9223372036854775808UL);
            x86_xor_register_width(ref output, bits.register, mask.register, true);
        }
        x86_move_scalar(ref output, destination.register, bits.register, size);
        x86_bind_register(ref state.registers, destination.register, instruction.result);
        state.accumulator = instruction.result;
        return "";
    }

    if (x86_scalar_float(ref program, instruction.type_id) && (instruction.opcode == WirOpcode.Add || instruction.opcode == WirOpcode.Subtract || instruction.opcode == WirOpcode.Multiply || instruction.opcode == WirOpcode.FloatDivide)) {
        if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
            return "floating arithmetic requires two operands and a result";
        }
        let size: Int = x86_scalar_size(ref program, instruction.type_id);
        if (size != 4 && size != 8) {
            return "the x86_64 lowering supports f32 and f64 arithmetic";
        }
        let left: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
        if (left.message.length() != 0) { return left.message; }
        let right: X86RegisterResult = x86_materialize_register_except(ref program, ref function, instruction.operands[1], slots, ref state, left.register, ref output);
        if (right.message.length() != 0) { return right.message; }
        // two-operand SSE overwrites the left value, spill it first if it stays live
        let save_error: String = x86_overwrite_operand(ref program, ref state, left.register, ref output);
        if (save_error.length() != 0) { return save_error; }
        let opcode: Int = 88;
        if (instruction.opcode == WirOpcode.Subtract) { opcode = 92; }
        else if (instruction.opcode == WirOpcode.Multiply) { opcode = 89; }
        else if (instruction.opcode == WirOpcode.FloatDivide) {
            opcode = 94;
        }
        if (!x86_sse_register(ref output, opcode, left.register, right.register, size)) {
            return "the SSE encoder rejected floating arithmetic operands";
        }
        x86_bind_register(ref state.registers, left.register, instruction.result);
        state.accumulator = instruction.result;
        return "";
    }

    if (instruction.opcode == WirOpcode.Add || instruction.opcode == WirOpcode.Subtract || instruction.opcode == WirOpcode.Multiply) {
        if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
            return "arithmetic instruction has the wrong operand count";
        }

        let result_type: WirType = program.arena.types[wir_id_index(UInt32(instruction.type_id))];
        let size: Int = x86_scalar_size(ref program, instruction.type_id);
        if ((result_type.kind != WirTypeKind.SignedInt && result_type.kind != WirTypeKind.UnsignedInt) || size == 0) {
            return "the x86_64 lowering supports integer arithmetic up to 64 bits";
        }

        let left_id: WirValueID = instruction.operands[0];
        let right_id: WirValueID = instruction.operands[1];
        let left_value: WirValue = program.arena.values[wir_id_index(UInt32(left_id))];
        let right: WirValue = program.arena.values[wir_id_index(UInt32(right_id))];
        if (instruction.opcode != WirOpcode.Subtract && left_value.kind == WirValueKind.Integer && right.kind != WirValueKind.Integer) {
            let swap = left_id;
            left_id = right_id;
            right_id = swap;
            right = left_value;
        }
        let left: X86RegisterResult = x86_materialize_register(ref program, ref function, left_id, slots, ref state, ref output);
        if (left.message.length() != 0) { return left.message; }

        let immediate: Bool = x86_integer_immediate(right, size);
        let right_register: X86Register = X86Register.None;
        if (!immediate) {
            let loaded_right: X86RegisterResult = x86_materialize_register_except(ref program, ref function, right_id, slots, ref state, left.register, ref output);
            if (loaded_right.message.length() != 0) { return loaded_right.message; }
            right_register = loaded_right.register;
        }

        let destination: X86Register = left.register;
        if (x86_next_use(ref state.registers.uses, left_id, state.position) != X86_NO_NEXT_USE) {
            let reuse_right: Bool = instruction.opcode != WirOpcode.Subtract &&
                                    right_register != X86Register.None &&
                                    x86_next_use(ref state.registers.uses, right_id, state.position) == X86_NO_NEXT_USE;
            if reuse_right {
                destination = right_register;
            } else {
                let choice: X86RegisterChoice = x86_choose_result_register_avoiding(ref program, ref state, instruction.result, left.register, right_register);
                let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
                if (prepare_error.length() != 0) { return prepare_error; }
                destination = choice.register;
                x86_move_scalar(ref output, destination, left.register, size);
            }
        }

        if immediate {
            if (instruction.opcode == WirOpcode.Add) {
                x86_add_register_imm(ref output, destination, UInt32(right.integer), size == 8);
            } else if (instruction.opcode == WirOpcode.Subtract) {
                x86_sub_register_imm(ref output, destination, UInt32(right.integer), size == 8);
            } else {
                x86_imul_register_imm(ref output, destination, UInt32(right.integer), size == 8);
            }
        } else {
            let source: X86Register = right_register;
            if (destination == right_register) { source = left.register; }

            if (size == 8) {
                if (instruction.opcode == WirOpcode.Add) {
                    x86_add_register64(ref output, destination, source);
                } else if (instruction.opcode == WirOpcode.Subtract) {
                    x86_sub_register64(ref output, destination, source);
                } else {
                    x86_imul_register64(ref output, destination, source);
                }
            } else {
                if (instruction.opcode == WirOpcode.Add) {
                    x86_add_register32(ref output, destination, source);
                }
                else if (instruction.opcode == WirOpcode.Subtract) {
                    x86_sub_register32(ref output, destination, source);
                }
                else {
                    x86_imul_register32(ref output, destination, source);
                }
            }
        }

        x86_normalize_scalar(ref output, destination, size, result_type.kind == WirTypeKind.SignedInt);
        x86_bind_register(ref state.registers, destination, instruction.result);
        state.accumulator = instruction.result;
        return "";
    }

    if (instruction.opcode == WirOpcode.BitAnd || instruction.opcode == WirOpcode.BitOr || instruction.opcode == WirOpcode.BitXor) {
        if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
            return "bitwise instruction has the wrong operand count";
        }
        let result_type: WirType = program.arena.types[wir_id_index(UInt32(instruction.type_id))];
        let size: Int = x86_scalar_size(ref program, instruction.type_id);
        if ((result_type.kind != WirTypeKind.SignedInt && result_type.kind != WirTypeKind.UnsignedInt && result_type.kind != WirTypeKind.BoolType) || size == 0) {
            return "the x86_64 lowering supports scalar integer and Bool bitwise operations up to 64 bits";
        }
        let left_id: WirValueID = instruction.operands[0];
        let right_id: WirValueID = instruction.operands[1];
        let left_value: WirValue = program.arena.values[wir_id_index(UInt32(left_id))];
        let right: WirValue = program.arena.values[wir_id_index(UInt32(right_id))];
        if (left_value.kind == WirValueKind.Integer && right.kind != WirValueKind.Integer) {
            let swap = left_id;
            left_id = right_id;
            right_id = swap;
            right = left_value;
        }
        let immediate: Bool = x86_integer_immediate(right, size);
        let left: X86RegisterResult = x86_materialize_register(ref program, ref function, left_id, slots, ref state, ref output);
        if (left.message.length() != 0) { return left.message; }

        let right_register: X86Register = X86Register.None;
        if (!immediate) {
            let loaded_right: X86RegisterResult = x86_materialize_register_except(ref program, ref function, right_id, slots, ref state, left.register, ref output);
            if (loaded_right.message.length() != 0) { return loaded_right.message; }
            right_register = loaded_right.register;
        }

        let destination: X86Register = left.register;
        if (x86_next_use(ref state.registers.uses, left_id, state.position) != X86_NO_NEXT_USE) {
            let choice: X86RegisterChoice = x86_choose_result_register_avoiding(ref program, ref state, instruction.result, left.register, right_register);
            let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
            destination = choice.register;
            x86_move_scalar(ref output, destination, left.register, size);
        }

        if immediate {
            let group: Int = 4;
            if (instruction.opcode == WirOpcode.BitOr) { group = 1; }
            else if (instruction.opcode == WirOpcode.BitXor) { group = 6; }
            x86_bitwise_register_imm(ref output, destination, UInt32(right.integer), group, size == 8);
        } else if (instruction.opcode == WirOpcode.BitAnd) {
            x86_and_register_width(ref output, destination, right_register, size == 8);
        } else if (instruction.opcode == WirOpcode.BitOr) {
            x86_or_register_width(ref output, destination, right_register, size == 8);
        } else {
            x86_xor_register_width(ref output, destination, right_register, size == 8);
        }
        x86_normalize_scalar(ref output, destination, size, result_type.kind == WirTypeKind.SignedInt);
        x86_bind_register(ref state.registers, destination, instruction.result);
        state.accumulator = instruction.result;
        return "";
    }

    if (instruction.opcode == WirOpcode.ShiftLeft || instruction.opcode == WirOpcode.SignedShiftRight || instruction.opcode == WirOpcode.UnsignedShiftRight) {
        if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
            return "shift instruction has the wrong operand count";
        }
        let result_type: WirType = program.arena.types[wir_id_index(UInt32(instruction.type_id))];
        let size: Int = x86_scalar_size(ref program, instruction.type_id);
        if ((result_type.kind != WirTypeKind.SignedInt && result_type.kind != WirTypeKind.UnsignedInt) || size == 0) {
            return "the x86_64 lowering supports integer shifts up to 64 bits";
        }
        let left_id: WirValueID = instruction.operands[0];
        let right_id: WirValueID = instruction.operands[1];
        let right: WirValue = program.arena.values[wir_id_index(UInt32(right_id))];
        if (right.kind != WirValueKind.Integer) {
            let clobber_error: String = x86_prepare_clobbers(ref program, ref state, x86_register_clobber(X86Register.RCX), ref output);
            if (clobber_error.length() != 0) { return clobber_error; }
        }
        let left: X86RegisterResult = x86_materialize_register(ref program, ref function, left_id, slots, ref state, ref output);
        if (left.message.length() != 0) { return left.message; }

        let right_register: X86Register = X86Register.None;
        if (right.kind != WirValueKind.Integer) {
            let loaded_right: X86RegisterResult = x86_materialize_register_except(ref program, ref function, right_id, slots, ref state, left.register, ref output);
            if (loaded_right.message.length() != 0) { return loaded_right.message; }
            right_register = loaded_right.register;
            x86_mov_register32(ref output, X86Register.RCX, right_register);
        }

        let destination: X86Register = left.register;
        if (x86_next_use(ref state.registers.uses, left_id, state.position) != X86_NO_NEXT_USE) {
            let choice: X86RegisterChoice = x86_choose_result_register_avoiding(ref program, ref state, instruction.result, left.register, right_register);
            let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
            destination = choice.register;
            x86_move_scalar(ref output, destination, left.register, size);
        }

        let group: Int = 4;
        if (instruction.opcode == WirOpcode.UnsignedShiftRight) { group = 5; }
        else if (instruction.opcode == WirOpcode.SignedShiftRight) {
            group = 7;
        }
        if (right.kind == WirValueKind.Integer) {
            x86_shift_register_imm8(ref output, destination, Byte(UInt32(right.integer) & 255U), group, size == 8);
        } else {
            x86_shift_register_cl(ref output, destination, group, size == 8);
        }
        x86_normalize_scalar(ref output, destination, size, result_type.kind == WirTypeKind.SignedInt);
        x86_bind_register(ref state.registers, destination, instruction.result);
        state.accumulator = instruction.result;
        return "";
    }

    if (instruction.opcode == WirOpcode.SignedDivide || instruction.opcode == WirOpcode.UnsignedDivide ||
        instruction.opcode == WirOpcode.SignedRemainder || instruction.opcode == WirOpcode.UnsignedRemainder) {
        if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
            return "division instruction has the wrong operand count";
        }
        let result_type: WirType = program.arena.types[wir_id_index(UInt32(instruction.type_id))];
        let size: Int = x86_scalar_size(ref program, instruction.type_id);
        if ((result_type.kind != WirTypeKind.SignedInt && result_type.kind != WirTypeKind.UnsignedInt) || size == 0) {
            return "the x86_64 lowering supports integer division up to 64 bits";
        }
        let clobbers: UInt64 = x86_register_clobber(X86Register.RAX) |
                                 x86_register_clobber(X86Register.RCX) |
                                 x86_register_clobber(X86Register.RDX);
        let clobber_error: String = x86_prepare_clobbers(ref program, ref state, clobbers, ref output);
        if (clobber_error.length() != 0) { return clobber_error; }
        let right: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[1], slots, ref state, ref output);
        if (right.message.length() != 0) { return right.message; }
        x86_move_scalar(ref output, X86Register.RCX, right.register, size);

        let left: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
        if (left.message.length() != 0) { return left.message; }
        let prepare_error: String = x86_prepare_fixed_register(ref program, ref state, X86Register.RAX, ref output);
        if (prepare_error.length() != 0) { return prepare_error; }
        if (left.register != X86Register.RAX) {
            x86_move_scalar(ref output, X86Register.RAX, left.register, size);
        }

        let signed: Bool = instruction.opcode == WirOpcode.SignedDivide || instruction.opcode == WirOpcode.SignedRemainder;
        x86_prepare_dividend(ref output, size == 8, signed);
        x86_div_register_width(ref output, X86Register.RCX, size == 8, signed);
        if (instruction.opcode == WirOpcode.SignedRemainder || instruction.opcode == WirOpcode.UnsignedRemainder) {
            x86_move_scalar(ref output, X86Register.RAX, X86Register.RDX, size);
        }
        x86_normalize_scalar(ref output, X86Register.RAX, size, result_type.kind == WirTypeKind.SignedInt);
        x86_bind_register(ref state.registers, X86Register.RAX, instruction.result);
        state.accumulator = instruction.result;
        return "";
    }

    if (instruction.opcode == WirOpcode.Abs) {
        if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
            return "abs instruction has the wrong operand count";
        }
        let result_type: WirType = program.arena.types[wir_id_index(UInt32(instruction.type_id))];
        let size: Int = x86_scalar_size(ref program, instruction.type_id);
        if (result_type.kind != WirTypeKind.SignedInt || size == 0) {
            return "the x86_64 lowering supports abs on signed integers up to 64 bits";
        }

        let preferred: X86Register = x86_preferred_register(ref state.registers.uses, instruction.result);
        let source: X86RegisterResult = x86_materialize_register_except(ref program, ref function, instruction.operands[0], slots, ref state, preferred, ref output);
        if (source.message.length() != 0) { return source.message; }
        let choice: X86RegisterChoice = x86_choose_result_register(ref program, ref state, instruction.result, source.register, false);
        let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
        if (prepare_error.length() != 0) { return prepare_error; }

        let operation_size: Int = 4;
        if (size == 8) { operation_size = 8; }
        x86_move_scalar(ref output, choice.register, source.register, operation_size);
        x86_unary_register(ref output, choice.register, 3, size == 8);
        x86_cmov_sign(ref output, choice.register, source.register, size == 8);
        x86_normalize_scalar(ref output, choice.register, size, true);
        x86_bind_register(ref state.registers, choice.register, instruction.result);
        state.accumulator = instruction.result;
        return "";
    }

    if (instruction.opcode == WirOpcode.Negate || instruction.opcode == WirOpcode.Not) {
        if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
            return "unary instruction has the wrong operand count";
        }
        let result_type: WirType = program.arena.types[wir_id_index(UInt32(instruction.type_id))];
        let size: Int = x86_scalar_size(ref program, instruction.type_id);
        let integer: Bool = result_type.kind == WirTypeKind.SignedInt || result_type.kind == WirTypeKind.UnsignedInt;
        if (size == 0 || (!integer && result_type.kind != WirTypeKind.BoolType) ||
            (instruction.opcode == WirOpcode.Negate && !integer)) {
            return "the x86_64 lowering cannot apply this unary operation to the result type";
        }
        let source_id: WirValueID = instruction.operands[0];
        let source: X86RegisterResult = x86_materialize_register(ref program, ref function, source_id, slots, ref state, ref output);
        if (source.message.length() != 0) { return source.message; }
        let destination: X86Register = source.register;
        if (x86_next_use(ref state.registers.uses, source_id, state.position) != X86_NO_NEXT_USE) {
            let choice: X86RegisterChoice = x86_choose_result_register(ref program, ref state, instruction.result, source.register, false);
            let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
            destination = choice.register;
            x86_move_scalar(ref output, destination, source.register, size);
        }
        if (instruction.opcode == WirOpcode.Negate) {
            x86_unary_register(ref output, destination, 3, size == 8);
        }
        else if (result_type.kind == WirTypeKind.BoolType) {
            x86_bitwise_register_imm32(ref output, destination, 1U, 6);
        }
        else {
            x86_unary_register(ref output, destination, 2, size == 8);
        }
        x86_normalize_scalar(ref output, destination, size, result_type.kind == WirTypeKind.SignedInt);
        x86_bind_register(ref state.registers, destination, instruction.result);
        state.accumulator = instruction.result;
        return "";
    }

    if (instruction.opcode == WirOpcode.FloatLess || instruction.opcode == WirOpcode.FloatLessEqual ||
        instruction.opcode == WirOpcode.FloatGreater || instruction.opcode == WirOpcode.FloatGreaterEqual ||
        ((instruction.opcode == WirOpcode.Equal || instruction.opcode == WirOpcode.NotEqual) && instruction.operands.length() == 2 &&
         x86_scalar_float(ref program, program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id))) {
        if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE || instruction.type_id != program.bool_type) {
            return "floating comparison has an invalid result or operand count";
        }
        let left_value: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
        let right_value: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[1]))];
        if (left_value.type_id != right_value.type_id || !x86_scalar_float(ref program, left_value.type_id)) {
            return "floating comparison requires matching f32 or f64 operands";
        }
        let left: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
        if (left.message.length() != 0) { return left.message; }
        let right: X86RegisterResult = x86_materialize_register_except(ref program, ref function, instruction.operands[1], slots, ref state, left.register, ref output);
        if (right.message.length() != 0) { return right.message; }
        let choice: X86RegisterChoice = x86_choose_result_register(ref program, ref state, instruction.result, X86Register.None, false);
        let prepare_error = x86_prepare_register(ref program, ref state, choice, ref output);
        if (prepare_error.length() != 0) { return prepare_error; }
        let comparison: X86Opcode = X86Opcode.Je;
        if (instruction.opcode == WirOpcode.NotEqual) { comparison = X86Opcode.Jne; }
        else if (instruction.opcode == WirOpcode.FloatLess) {
            comparison = X86Opcode.Jb;
        }
        else if (instruction.opcode == WirOpcode.FloatLessEqual) {
            comparison = X86Opcode.Jbe;
        }
        else if (instruction.opcode == WirOpcode.FloatGreater) {
            comparison = X86Opcode.Ja;
        }
        else if (instruction.opcode == WirOpcode.FloatGreaterEqual) { comparison = X86Opcode.Jae; }
        let parity: X86RegisterChoice = X86RegisterChoice(register=X86Register.None, evicted=NO_WIR_VALUE);
        if (comparison != X86Opcode.Ja && comparison != X86Opcode.Jae) {
            parity = x86_choose_register_except(ref program, ref state.registers, state.position, choice.register);
            prepare_error = x86_prepare_register(ref program, ref state, parity, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
        }
        if (!x86_sse_compare(ref output, left.register, right.register, x86_scalar_size(ref program, left_value.type_id)) ||
            !x86_set_condition_register(ref output, choice.register, comparison)) {
            return "the x86_64 encoder rejected the floating comparison";
        }
        // unordered sets ZF, CF and PF, only != accepts that result
        if (parity.register != X86Register.None) {
            let condition: X86Opcode = X86Opcode.Jnp;
            if (comparison == X86Opcode.Jne) { condition = X86Opcode.Jp; }
            x86_set_condition_register(ref output, parity.register, condition);
            if (comparison == X86Opcode.Jne) {
                x86_or_register_width(ref output, choice.register, parity.register, false);
            }
            else {
                x86_and_register_width(ref output, choice.register, parity.register, false);
            }
        }
        x86_bind_register(ref state.registers, choice.register, instruction.result);
        state.accumulator = instruction.result;
        // branch lowering tests the materialized Bool, not the unordered SSE flags
        return "";
    }

    let comparison: X86Opcode = x86_comparison_opcode(instruction.opcode);
    if (comparison != X86Opcode.Invalid) {
        if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE || instruction.type_id != program.bool_type) {
            return "comparison instruction has an invalid result or operand count";
        }
        let right_id: WirValueID = instruction.operands[1];
        let right: WirValue = program.arena.values[wir_id_index(UInt32(right_id))];
        let left_value: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
        if (x86_scalar_float(ref program, left_value.type_id)) {
            return "floating comparisons are not yet supported by the machine backend";
        }
        let size: Int = x86_scalar_size(ref program, left_value.type_id);
        if (size == 0) {
            return "the x86_64 lowering cannot compare this value type";
        }
        let left: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
        if (left.message.length() != 0) { return left.message; }
        let result_register: X86Register = X86Register.None;
        if (x86_next_use(ref state.registers.uses, instruction.operands[0], state.position) == X86_NO_NEXT_USE) {
            result_register = left.register;
        }

        if (x86_integer_immediate(right, size)) {
            // narrow registers are extended to 32 bits, compare constants in the same form
            let immediate: UInt32 = UInt32(right.integer);
            if (size == 1) {
                immediate &= 255U;
                if (x86_scalar_signed(ref program, right.type_id) && (immediate & 128U) != 0U) {
                    immediate |= 4294967040U;
                }
            } else if (size == 2) {
                immediate &= 65535U;
                if (x86_scalar_signed(ref program, right.type_id) && (immediate & 32768U) != 0U) {
                    immediate |= 4294901760U;
                }
            }
            x86_cmp_register_imm(ref output, left.register, immediate, size == 8);
        } else {
            let loaded_right: X86RegisterResult = x86_materialize_register_except(ref program, ref function, right_id, slots, ref state, left.register, ref output);
            if (loaded_right.message.length() != 0) { return loaded_right.message; }
            if (size == 8) {
                x86_cmp_register64(ref output, left.register, loaded_right.register);
            }
            else {
                x86_cmp_register32(ref output, left.register, loaded_right.register);
            }
            if (result_register == X86Register.None && x86_next_use(ref state.registers.uses, right_id, state.position) == X86_NO_NEXT_USE) {
                result_register = loaded_right.register;
            }
        }
        let choice: X86RegisterChoice = X86RegisterChoice(register=X86Register.None, evicted=NO_WIR_VALUE);
        if (x86_preferred_register(ref state.registers.uses, instruction.result) == X86Register.RAX &&
            x86_result_register_available(ref program, ref state, X86Register.RAX)) {
            choice = x86_choose_result_register(ref program, ref state, instruction.result, X86Register.None, false);
        } else if (result_register != X86Register.None) {
            // cmp has consumed both operands, so setcc can reuse a dead operand register
            x86_clear_register(ref state.registers, result_register);
            choice = X86RegisterChoice(register=result_register, evicted=NO_WIR_VALUE);
        } else {
            choice = x86_choose_register(ref program, ref state.registers, state.position);
        }
        let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
        if (prepare_error.length() != 0) { return prepare_error; }

        if (!x86_set_condition_register(ref output, choice.register, comparison)) {
            return "the x86_64 encoder rejected the comparison condition";
        }

        x86_bind_register(ref state.registers, choice.register, instruction.result);

        state.accumulator = instruction.result;
        state.flags_value = instruction.result;
        state.flags_opcode = comparison;
        return "";
    }

    if (instruction.opcode == WirOpcode.Call) {
        if (instruction.operands.length() == 0 || instruction.call_type == NO_WIR_TYPE) {
            return "call requires a target and a function signature";
        }

        let callee: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
        let callee_type: WirType = program.arena.types[wir_id_index(UInt32(callee.type_id))];
        if (callee_type.kind != WirTypeKind.Function && callee_type.kind != WirTypeKind.Pointer) {
            return "the x86_64 call target must be a function address";
        }

        let signature: WirType = machine_call_signature(ref program, instruction);
        if (signature.kind != WirTypeKind.Function ||
            instruction.operands.length() - 1 != signature.parameters.length()) {
            return "the x86_64 call arguments do not match the function signature";
        }
        let storage: X86CallStorage = x86_call_storage(ref program, signature, state.layouts);
        if (storage.size < 0) {
            return "call storage exceeds the addressable stack frame";
        }
        let hidden: Bool = storage.result >= 0;
        let native_sysv: Bool = x86_native_sysv_abi(signature.abi);
        let native_layout: X86SysVCallLayout = X86SysVCallLayout(hidden=X86Register.None, arguments=[], stack_size=0);
        if native_sysv {
            x86_plan_sysv_call(ref program, signature, state.layouts, hidden, ref native_layout);
        }
        let locations: Vector(X86ArgLocation) = [];
        if (x86_is_sysv_abi() && !native_sysv) {
            locations = x86_sysv_call_locations(ref program, signature, state.layouts, hidden);
        }
        if (instruction.result != NO_WIR_VALUE && !hidden &&
            x86_native_abi_size(ref program, instruction.type_id, state.layouts, signature.abi) == 0) {
            return "call result requires an unsupported machine ABI representation";
        }
        let save_error: String = x86_save_live_registers(ref program, slots, instruction.operands, ref state, ref output);
        if (save_error.length() != 0) { return save_error; }
        let argument_index: Int = 0;
        // copies cannot use SSA homes, one value may be passed more than once
        while (argument_index < signature.parameters.length()) {
            if (storage.arguments[argument_index] >= 0) {
                let copy_error = x86_store_value(
                    ref program,
                    ref function,
                    instruction.operands[argument_index + 1],
                    X86Register.RSP,
                    storage.arguments[argument_index],
                    slots,
                    ref state,
                    ref output
                );
                if (copy_error.length() != 0) { return copy_error; }
            }
            argument_index++;
        }
        // first place the register arguments in Win64's shadow space. Loading
        // the ABI registers only after every source has been read avoids a
        // parallel-copy problem and leaves the allocator free to use R8/R9.
        if (!native_sysv) {
            argument_index = 0;
            while (argument_index < signature.parameters.length()) {
                let size: Int = x86_abi_size(ref program, signature.parameters[argument_index], state.layouts);
                let position: Int = argument_index;
                if hidden { position++; }
                let offset: Int = position * 8;
                if (!x86_is_sysv_abi() && position >= 4) { offset = x86_stack_arg_offset(position); }
                if (offset < 0) {
                    return "the x86_64 ABI has no stack location for this argument";
                }

                if (storage.arguments[argument_index] >= 0) {
                    size = 8;
                    let choice: X86RegisterChoice = x86_choose_register(ref program, ref state.registers, state.position);
                    let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
                    if (prepare_error.length() != 0) { return prepare_error; }
                    x86_lea(ref output, choice.register, X86Register.RSP, X86Register.None, 1, storage.arguments[argument_index]);
                    x86_store_scalar(ref output, choice.register, X86Register.RSP, offset, size);
                } else {
                    if (size == 0) {
                        return "call argument requires an unsupported machine ABI representation";
                    }
                    let store_error: String = x86_store_value(
                        ref program,
                        ref function,
                        instruction.operands[argument_index + 1],
                        X86Register.RSP,
                        offset,
                        slots,
                        ref state,
                        ref output
                    );
                    if (store_error.length() != 0) { return store_error; }
                }
                argument_index++;
            }
        }

        let indirect_target: X86Register = X86Register.None;
        if (callee.kind != WirValueKind.Function) {
            let target: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
            if (target.message.length() != 0) { return target.message; }
            indirect_target = X86Register.R11;
            if (target.register != indirect_target) {
                let target_error: String = x86_prepare_fixed_register(ref program, ref state, indirect_target, ref output);
                if (target_error.length() != 0) { return target_error; }
                x86_mov_register64(ref output, indirect_target, target.register);
            }
        }

        x86_reset_registers(ref state.registers);
        if native_sysv {
            // copy stack arguments before loading RCX, the bulk copy loop uses it.
            argument_index = 0;
            while (argument_index < signature.parameters.length()) {
                let location: X86SysVValueLocation = native_layout.arguments[argument_index];
                let source: Int = storage.arguments[argument_index];
                if (location.stack_offset >= 0) {
                    if (!x86_copy_memory(ref output, X86Register.RSP, location.stack_offset, X86Register.RSP, source,
                        location.size, X86Register.RAX)) {
                        return "the SysV ABI could not copy a stack argument";
                    }
                }
                argument_index++;
            }
            argument_index = 0;
            while (argument_index < signature.parameters.length()) {
                let location: X86SysVValueLocation = native_layout.arguments[argument_index];
                let source: Int = storage.arguments[argument_index];
                if (location.stack_offset < 0) {
                    let first_size: Int = location.size;
                    if (first_size > 8) { first_size = 8; }
                    if (location.count > 0 && (location.first == X86Register.None ||
                        !x86_load_abi_part(ref output, location.first, X86Register.RSP, source, first_size, X86Register.RAX))) {
                        return "the SysV ABI could not load the first argument eightbyte";
                    }
                    if (location.count > 1) {
                        let second_size: Int = location.size - 8;
                        if (location.second == X86Register.None || second_size <= 0 ||
                            !x86_load_abi_part(ref output, location.second, X86Register.RSP, source + 8, second_size, X86Register.RAX)) {
                            return "the SysV ABI could not load the second argument eightbyte";
                        }
                    }
                }
                argument_index++;
            }
        } else {
            argument_index = 0;
            while (argument_index < signature.parameters.length()) {
                let position: Int = argument_index;
                if (hidden) { position++; }
                let destination: X86Register = x86_argument_register(
                    position,
                    storage.arguments[argument_index] < 0 && x86_scalar_float(ref program, signature.parameters[argument_index])
                );
                if (x86_is_sysv_abi()) { destination = locations[position].register; }
                if (destination != X86Register.None) {
                    let size: Int = x86_abi_size(ref program, signature.parameters[argument_index], state.layouts);
                    if (storage.arguments[argument_index] >= 0) { size = 8; }
                    if (size == 0 || !x86_load_scalar(ref output, destination, X86Register.RSP, position * 8, size, false)) {
                        return "the x86_64 ABI cannot load a staged call argument";
                    }
                    if (signature.variadic && !x86_is_sysv_abi() && x86_is_xmm(destination)) {
                        // Win64 varargs duplicate floating arguments in their positional GP register.
                        let gp = x86_argument_register(position, false);
                        if (!x86_load_scalar(ref output, gp, X86Register.RSP, position * 8, size, false)) {
                            return "cannot duplicate a Win64 variadic float argument";
                        }
                    }
                }
                argument_index++;
            }
            if (x86_is_sysv_abi()) {
                argument_index = 0;
                while (argument_index < signature.parameters.length()) {
                    let position: Int = argument_index;
                    if hidden { position++; }
                    let location: X86ArgLocation = locations[position];
                    if (location.stack_offset >= 0) {
                        let source_offset: Int = position * 8;
                        let target_offset: Int = location.stack_offset;
                        if (!x86_load_scalar(ref output, X86Register.RAX, X86Register.RSP, source_offset, 8, false) ||
                            !x86_store_scalar(ref output, X86Register.RAX, X86Register.RSP, target_offset, 8)) {
                            return "the x86_64 ABI could not stage a stack argument";
                        }
                    }
                    argument_index++;
                }
            }
        }
        if hidden {
            let hidden_register: X86Register = x86_argument_register(0, false);
            if native_sysv {
                hidden_register = native_layout.hidden;
            } else if (x86_is_sysv_abi()) {
                hidden_register = locations[0].register;
            }
            if (hidden_register == X86Register.None) {
                return "the x86_64 ABI has no hidden return register";
            }
            x86_lea(ref output, hidden_register, X86Register.RSP, X86Register.None, 1, storage.result);
        }

        if (signature.variadic && native_sysv) {
            // SysV's AL counts vector registers, including the named arguments.
            let count = 0;
            let i = 0;
            while (i < native_layout.arguments.length()) {
                let arg = native_layout.arguments[i];
                if (arg.stack_offset < 0) {
                    if (arg.first_class == X86SysVClass.SSE) { count++; }
                    if (arg.count > 1 && arg.second_class == X86SysVClass.SSE) { count++; }
                }
                i++;
            }
            x86_mov_register_imm32(ref output, X86Register.RAX, UInt32(count));
        }
        if (callee.kind == WirValueKind.Function) {
            let target_function: WirFuncID = WirFuncID(callee.owner);
            calls.append(X86CallFixup(offset=x86_call_rel32(ref output), target=target_function));
        } else {
            if (!x86_call_register(ref output, indirect_target)) {
                return "the x86_64 encoder rejected the indirect call target";
            }
        }

        // all allocator registers are caller-saved, including reloaded arguments
        x86_reset_registers(ref state.registers);
        if (instruction.result != NO_WIR_VALUE) {
            if (native_sysv && x86_memory_value(ref program, instruction.type_id)) {
                let home: Int = x86_stack_offset(ref state.stack, instruction.result);
                if (home == 0) {
                    return "native aggregate call result has no storage";
                }
                if hidden {
                    let layout: WirTypeLayout = state.layouts[wir_id_index(UInt32(instruction.type_id))];
                    if (!x86_copy_memory(ref output, X86Register.RBP, home, X86Register.RSP, storage.result,
                        Int(layout.size), X86Register.RAX)) {
                        return "cannot copy indirect native call result";
                    }
                } else {
                    let classification: X86SysVTypeClass = x86_sysv_classify(ref program, instruction.type_id, state.layouts);
                    let integer_index: Int = 0;
                    let float_index: Int = 0;
                    let part: Int = 0;
                    while (part < classification.count) {
                        let abi_class: X86SysVClass = classification.first;
                        if (part == 1) { abi_class = classification.second; }
                        let class_index: Int = integer_index;
                        if (abi_class == X86SysVClass.SSE) {
                            class_index = float_index;
                            float_index++;
                        } else {
                            integer_index++;
                        }
                        let returned: X86Register = x86_sysv_return_register(class_index, abi_class);
                        let part_size: Int = classification.size - part * 8;
                        if (part_size > 8) { part_size = 8; }
                        if (returned == X86Register.None || part_size <= 0 ||
                            !x86_store_abi_part(ref output, returned, X86Register.RBP, home + part * 8, part_size, X86Register.R11)) {
                            return "cannot save a native aggregate call result";
                        }
                        part++;
                    }
                }
            } else if (x86_wide_integer(ref program, instruction.type_id)) {
                let home = x86_stack_offset(ref state.stack, instruction.result);
                if (home == 0 || !x86_sse_vector_memory(ref output, X86Register.XMM0, X86Register.RBP, home, false)) {
                    return "cannot save a 128-bit integer call result";
                }
            } else if (x86_aggregate_type(ref program, instruction.type_id)) {
                let home = x86_stack_offset(ref state.stack, instruction.result);
                if (home == 0) {
                    return "aggregate call result has no storage";
                }
                if hidden {
                    let layout: WirTypeLayout = state.layouts[wir_id_index(UInt32(instruction.type_id))];
                    if (!x86_copy_memory(ref output, X86Register.RBP, home, X86Register.RSP, storage.result, Int(layout.size), X86Register.RAX)) {
                        return "cannot copy indirect call result";
                    }
                } else {
                    x86_store_scalar(ref output, X86Register.RAX, X86Register.RBP, home, x86_abi_size(ref program, instruction.type_id, state.layouts));
                }
            } else if (x86_scalar_float(ref program, instruction.type_id)) {
                let choice: X86RegisterChoice = x86_choose_register_class(ref program, ref state.registers, state.position, X86Register.None, true);
                x86_move_scalar(ref output, choice.register, X86Register.XMM0, x86_scalar_size(ref program, instruction.type_id));
                x86_bind_register(ref state.registers, choice.register, instruction.result);
            } else {
                x86_normalize_scalar(ref output, X86Register.RAX, x86_scalar_size(ref program, instruction.type_id), x86_scalar_signed(ref program, instruction.type_id));
                x86_bind_register(ref state.registers, X86Register.RAX, instruction.result);
            }
        }

        state.accumulator = instruction.result;
        return "";
    }

    if (instruction.opcode == WirOpcode.Trap || instruction.opcode == WirOpcode.Unreachable) {
        if (instruction.operands.length() != 0 || instruction.result != NO_WIR_VALUE) {
            return "trap instruction cannot have operands or a result";
        }
        x86_trap(ref output);
        state.accumulator = NO_WIR_VALUE;
        return "";
    }

    if (instruction.opcode == WirOpcode.Jump) {
        if (instruction.operands.length() != 0 || instruction.edges.length() != 1) {
            return "jump instruction has an unsupported edge shape";
        }
        let move_error: String = x86_emit_edge_moves(ref program, ref function, instruction.edges[0], slots, scratch, state, ref output);
        if (move_error.length() != 0) { return move_error; }

        fixups.append(X86BranchFixup(offset=x86_jump_rel32(ref output), target=instruction.edges[0].target));
        return "";
    }

    if (instruction.opcode == WirOpcode.Branch) {
        if (instruction.operands.length() != 1 || instruction.edges.length() != 2) {
            return "branch instruction has an unsupported edge shape";
        }

        let condition: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
        if (condition.kind == WirValueKind.BoolValue) {
            let edge = 1;
            if (condition.integer != UInt128(0U)) { edge = 0; }

            let move_error: String = x86_emit_edge_moves(ref program, ref function, instruction.edges[edge], slots, scratch, state, ref output);
            if (move_error.length() != 0) { return move_error; }

            fixups.append(X86BranchFixup(offset=x86_jump_rel32(ref output), target=instruction.edges[edge].target));
            return "";
        }

        if (instruction.operands[0] != state.flags_value || state.flags_opcode == X86Opcode.Invalid) {
            let condition_value: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
            if (condition_value.type_id != program.bool_type) {
                return "branch condition is not Bool";
            }
            let condition_register: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
            if (condition_register.message.length() != 0) { return condition_register.message; }
            x86_test_register_width(ref output, condition_register.register, condition_register.register, false);
            state.flags_opcode = X86Opcode.Jne;
        }
        if (instruction.edges[0].arguments.length() == 0 && instruction.edges[1].arguments.length() == 0) {
            let direct_patch: Int = x86_jump_if_rel32(ref output, state.flags_opcode);
            if (direct_patch < 0) {
                return "the x86_64 encoder rejected the branch condition";
            }

            fixups.append(X86BranchFixup(offset=direct_patch, target=instruction.edges[0].target));
            fixups.append(X86BranchFixup(offset=x86_jump_rel32(ref output), target=instruction.edges[1].target));
            return "";
        }

        let true_patch: Int = x86_jump_if_rel32(ref output, state.flags_opcode);
        if (true_patch < 0) {
            return "the x86_64 encoder rejected the branch condition";
        }

        let false_move_error: String = x86_emit_edge_moves(ref program, ref function, instruction.edges[1], slots, scratch, state, ref output);
        if (false_move_error.length() != 0) { return false_move_error; }

        fixups.append(X86BranchFixup(offset=x86_jump_rel32(ref output), target=instruction.edges[1].target));

        let true_offset: Int = output.bytes.length();
        if (!x86_patch_i32(ref output, true_patch, true_offset - (true_patch + 4))) {
            return "the x86_64 lowering could not resolve the true edge transfer";
        }
        let true_move_error: String = x86_emit_edge_moves(ref program, ref function, instruction.edges[0], slots, scratch, state, ref output);
        if (true_move_error.length() != 0) { return true_move_error; }

        fixups.append(X86BranchFixup(offset=x86_jump_rel32(ref output), target=instruction.edges[0].target));
        return "";
    }

    if (instruction.opcode == WirOpcode.Return) {
        if (instruction.operands.length() == 1) {
            let ptr value: WirValue = ref program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
            // both return ABIs may read the home directly, commit a dirty pair first.
            if (x86_wide_integer(ref program, value.type_id) &&
                !x86_spill_wide_value(ref state, instruction.operands[0], ref output)) {
                return "cannot save a 128-bit integer before returning";
            }

            let return_signature: WirType = program.arena.types[wir_id_index(UInt32(function.type_id))];
            let native_sysv: Bool = x86_native_sysv_abi(return_signature.abi);
            if (native_sysv && x86_memory_value(ref program, value.type_id)) {
                if (x86_indirect_return(ref program, value.type_id, state.layouts, return_signature.abi)) {
                    if (state.return_pointer == 0) {
                        return "indirect return has no saved destination";
                    }
                    let copy_error: String = x86_prepare_fixed_register(ref program, ref state, X86Register.R10, ref output);
                    if (copy_error.length() != 0) { return copy_error; }
                    x86_load_scalar(ref output, X86Register.R10, X86Register.RBP, state.return_pointer, 8, false);
                    copy_error = x86_store_value(ref program, ref function, instruction.operands[0], X86Register.R10, 0, slots, ref state, ref output);
                    if (copy_error.length() != 0) { return copy_error; }
                    x86_mov_register64(ref output, X86Register.RAX, X86Register.R10);
                } else {
                    let classification: X86SysVTypeClass = x86_sysv_classify(ref program, value.type_id, state.layouts);
                    let home: Int = x86_stack_offset(ref state.stack, instruction.operands[0]);
                    let zero: Bool = value.kind == WirValueKind.Constant &&
                        program.arena.constants[wir_id_index(value.owner)].kind == WirConstKind.Zero;
                    let integer_index: Int = 0;
                    let float_index: Int = 0;
                    let part: Int = 0;
                    while (part < classification.count) {
                        let abi_class: X86SysVClass = classification.first;
                        if (part == 1) { abi_class = classification.second; }
                        let class_index: Int = integer_index;
                        if (abi_class == X86SysVClass.SSE) {
                            class_index = float_index;
                            float_index++;
                        } else {
                            integer_index++;
                        }
                        let destination: X86Register = x86_sysv_return_register(class_index, abi_class);
                        let part_size: Int = classification.size - part * 8;
                        if (part_size > 8) { part_size = 8; }
                        if (destination == X86Register.None || part_size <= 0) {
                            return "native aggregate has no return register";
                        }
                        if (home != 0) {
                            if (!x86_load_abi_part(ref output, destination, X86Register.RBP, home + part * 8, part_size, X86Register.R11)) {
                                return "cannot load a native aggregate return value";
                            }
                        } else if zero {
                            if (abi_class == X86SysVClass.SSE) {
                                x86_mov_register_imm32(ref output, X86Register.R10, 0U);
                                if (!x86_sse_bits(ref output, destination, X86Register.R10, part_size, true)) {
                                    return "cannot clear a native SSE return register";
                                }
                            } else {
                                x86_mov_register_imm32(ref output, destination, 0U);
                            }
                        } else {
                            return "native aggregate return value has no storage";
                        }
                        part++;
                    }
                }
                if (frame_size > 0) { x86_frame_leave(ref output); }
                x86_return(ref output);
                return "";
            }
            if (x86_wide_integer(ref program, value.type_id)) {
                let home = x86_stack_offset(ref state.stack, instruction.operands[0]);
                if (home != 0) {
                    if (!x86_sse_vector_memory(ref output, X86Register.XMM0, X86Register.RBP, home, true)) {
                        return "cannot load a 128-bit integer return value";
                    }
                } else {
                    let load_error = x86_load_wide_half(ref program, instruction.operands[0], false, X86Register.RAX, ref state, ref output);
                    if (load_error.length() == 0) {
                        load_error = x86_load_wide_half(ref program, instruction.operands[0], true, X86Register.R10, ref state, ref output);
                    }
                    if (load_error.length() != 0 || !x86_sse_bits(ref output, X86Register.XMM0, X86Register.RAX, 8, true) ||
                        !x86_sse_bits(ref output, X86Register.XMM1, X86Register.R10, 8, true) ||
                        !x86_sse_pair(ref output, X86Register.XMM0, X86Register.XMM1)) {
                        return "cannot encode a 128-bit integer return value";
                    }
                }
                if (frame_size > 0) {
                    x86_frame_leave(ref output);
                }
                x86_return(ref output);
                return "";
            }
            if (x86_indirect_return(ref program, value.type_id, state.layouts, return_signature.abi)) {
                if (state.return_pointer == 0) {
                    return "indirect return has no saved destination";
                }
                let copy_error = x86_prepare_fixed_register(ref program, ref state, X86Register.R10, ref output);
                if (copy_error.length() != 0) { return copy_error; }
                x86_load_scalar(ref output, X86Register.R10, X86Register.RBP, state.return_pointer, 8, false);
                copy_error = x86_store_value(ref program, ref function, instruction.operands[0], X86Register.R10, 0, slots, ref state, ref output);
                if (copy_error.length() != 0) { return copy_error; }
                x86_mov_register64(ref output, X86Register.RAX, X86Register.R10);
                x86_frame_leave(ref output);
                x86_return(ref output);
                return "";
            }
            let size: Int = x86_abi_size(ref program, value.type_id, state.layouts);
            if (size == 0) {
                return "unsupported return operand in the x86_64 lowering";
            }
            let returned: X86RegisterResult = x86_materialize_abi_value(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
            if (returned.message.length() != 0) { return returned.message; }

            let destination: X86Register = X86Register.RAX;
            if (x86_scalar_float(ref program, value.type_id)) { destination = X86Register.XMM0; }
            if (returned.register != destination) {
                x86_move_scalar(ref output, destination, returned.register, size);
            }

            if (frame_size > 0) {
                x86_frame_leave(ref output);
            }

            x86_return(ref output);
            return "";
        }
        if (instruction.operands.length() == 0) {
            if (frame_size > 0) {
                x86_frame_leave(ref output);
            }

            x86_return(ref output);
            return "";
        }

        return "return instruction has the wrong operand count";
    }

    return "unsupported instruction in the initial x86_64 lowering";
}

func x86_lower_function(ref program: WirModule, function_id: WirFuncID) -> X86LoweringResult {
// standalone callers supply legalized WIR, module lowering inserts required helpers first
    return x86_lower_function_with_layouts(
        ref program,
        function_id,
        x86_type_layouts(ref program),
        x86_find_function(ref program, "__wl_retain"),
        x86_find_function(ref program, "__wl_release"),
        x86_find_function(ref program, "__wl_fail_null"),
        x86_find_function(ref program, "__wl_fail_bounds")
    );
}

func x86_lower_function_with_layouts(
    ref program: WirModule,
    function_id: WirFuncID,
    layouts: Vector(WirTypeLayout),
    retain_function: WirFuncID,
    release_function: WirFuncID,
    null_function: WirFuncID,
    bounds_function: WirFuncID
) -> X86LoweringResult {
    let is_windows: Bool = program.target == "x86_64-pc-windows-msvc";
    let is_linux: Bool = program.target == "x86_64-unknown-linux-gnu";
    if ((!is_windows && !is_linux) || !machine_layout_valid(program)) {
        return x86_lowering_error("the x86_64 machine backend does not support this target");
    }
    let function_index: Int = wir_id_index(UInt32(function_id));
    if (function_index < 0 || function_index >= program.arena.functions.length()) {
        return x86_lowering_error("function id is outside the WIR function table");
    }

    let function: WirFunction = program.arena.functions[function_index];
    if (function.linkage == WirLinkage.External) {
        return x86_lowering_error("external functions do not have machine code");
    }
    let signature: WirType = program.arena.types[wir_id_index(UInt32(function.type_id))];
    let indirect_return = x86_indirect_return(ref program, signature.result, layouts, signature.abi);
    let order: Vector(WirBlockID) = x86_block_order(function);
    if (order.length() == 0 || order.length() != function.blocks.length()) {
        return x86_lowering_error("the x86_64 lowering could not find the function entry block");
    }

    let analysis: X86FunctionAnalysis = x86_analyze_function(ref program, function_id, function, order, layouts);
    if (analysis.message.length() != 0) {
        return x86_lowering_error(analysis.message);
    }

    let located_values: Int = analysis.located_values;
    let home_parameters: Bool = analysis.home_parameters;
    if (indirect_return || order.length() > 1) {
        home_parameters = true;
    }

    let const_homes = x86_const_homes(ref program, order);
    // constant initialization uses scratch registers before the first instruction
    if (const_homes.length() != 0) {
        home_parameters = true;
    }

    let cross: X86ValueFlags = x86_cross_block_values(ref program, order);
    let block_index: Int = 0;
    while (block_index < order.length()) {
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(order[block_index]))];

        let i = 0;
        while (i < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[i]))];
            if (instruction.result != NO_WIR_VALUE && instruction.opcode != WirOpcode.StackAlloc &&
                (x86_flag(cross, instruction.result) || x86_memory_value(ref program, instruction.type_id))) {
                located_values++;
            }

            i++;
        }

        block_index++;
    }
    let uses: X86UseTable = x86_collect_uses(ref program, order);
    x86_mark_return_registers(ref program, order, ref uses);
    if (analysis.edge_scratch != 0) {
        x86_mark_edge_registers(ref program, order, ref uses);
    }
    let slots: Vector(X86StackSlot) = x86_stack_slots_with_uses(ref program, function, order, home_parameters, cross, layouts, uses);
    if home_parameters { located_values += function.parameters.length(); }
    if (slots.length() != located_values) {
        return x86_lowering_error("the x86_64 lowering could not lay out a stack slot");
    }
    if (!x86_add_const_slots(ref program, const_homes, layouts, ref slots)) {
        return x86_lowering_error("the x86_64 lowering could not lay out aggregate constants");
    }
    let value_range: X86ValueRange = x86_function_value_range(ref program, order);
    let stack: X86StackIndex = x86_stack_index(slots, value_range);
    let scratch: Vector(Int) = x86_edge_scratch(ref program, order, slots, layouts, analysis.edge_scratch);
    if (scratch.length() != analysis.edge_scratch) {
        return x86_lowering_error("the x86_64 lowering could not lay out edge staging storage");
    }
    let register_plan: X86RegisterPlan = x86_register_plan(uses);
    let register_count: Int = 3;

    // the smaller register bank gives a conservative mixed-class spill bound
    let spill_count: Int = x86_spill_capacity(ref program, order, ref uses, register_count);

    // fixed scratch registers may still contain live values, reserve their spills too
    if (analysis.integer_division) { spill_count += 1; }
    if (analysis.u64_cast) { spill_count += 1; }
    if (analysis.float_negate) { spill_count += 3; }
    if (analysis.wide_operation) { spill_count += 3; }
    let spill_locations: Vector(Int) = x86_spill_locations(slots, scratch, spill_count);
    if (spill_locations.length() != spill_count) {
        return x86_lowering_error("the x86_64 lowering could not lay out spill storage");
    }
    let spill_plan: X86SpillPlan = x86_spill_plan_for_range(spill_locations, value_range);

    let frame_size: Int = x86_stack_frame_size(slots, scratch, spill_locations);
    if (frame_size < 0 || (indirect_return && frame_size > 2147483632 - 8)) {
        return x86_lowering_error("the x86_64 stack frame is too large");
    }
    let return_pointer = 0;
    if indirect_return {
        frame_size = x86_align_frame_offset(frame_size + 8, 16);
        return_pointer = -frame_size;
    }
    let call_frame: Int = analysis.call_frame;
    if (call_frame < 0 || call_frame > 2147483632 - frame_size) {
        return x86_lowering_error("outgoing call storage exceeds the addressable stack frame");
    }
    if (call_frame > 0) { frame_size = x86_align_frame_offset(frame_size + call_frame, 16); }
    let output: X86CodeBuffer = x86_new_code_buffer();
    let offsets: Vector(X86BlockOffset) = [];
    let fixups: Vector(X86BranchFixup) = [];
    let calls: Vector(X86CallFixup) = [];
    let position: Int = 0;
    let unwind: Vector(Byte) = [];
    if (frame_size > 0) {
        if (program.target == "x86_64-pc-windows-msvc") {
            unwind = x86_win64_frame(ref output, frame_size);
            if (unwind.length() == 0) { return x86_lowering_error("cannot describe the Windows stack frame"); }
        } else {
            x86_frame_enter(ref output, frame_size);
        }
    }
    if indirect_return {
        // The hidden destination follows the normal integer argument bank,
        // RCX on Win64 and RDI on SysV, before user parameters are assigned.
        let return_register: X86Register = x86_argument_register(0, false);
        x86_store_scalar(ref output, return_register, X86Register.RBP, return_pointer, 8);
    }
    if (home_parameters && !x86_home_parameters(ref program, function, stack, layouts, ref output)) {
        return x86_lowering_error("the x86_64 lowering could not save function parameters");
    }

    let predecessors: Dict(UInt32, Int) = x86_predecessor_counts(ref program, order);
    let carry_registers: Bool = false;
    block_index = 0;
    while (block_index < order.length()) {
        let block_id: WirBlockID = order[block_index];
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(block_id))];
        offsets.append(X86BlockOffset(block=block_id, offset=output.bytes.length()));
        // a straight edge with one predecessor has one unambiguous machine
        // state. Merge blocks still start from fixed homes.
        if (!carry_registers) {
            x86_reset_registers(ref register_plan);
            x86_reset_spills(ref spill_plan);
        }
        let param_index = 0;
        while (param_index < block.parameters.length()) {
            let param: WirValueID = block.parameters[param_index];
            let incoming: X86Register = x86_incoming_register(ref register_plan.uses, param);
            if (incoming != X86Register.None) {
                x86_bind_register(ref register_plan, incoming, param);
            }
            param_index++;
        }
        if (block_index == 0 && order.length() == 1 && !home_parameters) {
            x86_bind_entry_parameters(ref program, ref function, ref register_plan, ref output);
        }

        let state: X86BlockState = X86BlockState(
            accumulator=NO_WIR_VALUE,
            flags_value=NO_WIR_VALUE,
            flags_opcode=X86Opcode.Invalid,
            registers=register_plan,
            spills=spill_plan,
            stack=stack,
            layouts=layouts,
            retain_function=retain_function,
            release_function=release_function,
            null_function=null_function,
            bounds_function=bounds_function,
            return_pointer=return_pointer,
            position=position,
            message=""
        );
        let instruction_index: Int = 0;
        if (block_index == 0) {
            for (let i = 0; i < const_homes.length(); i++) {
                let offset = x86_stack_offset(ref state.stack, const_homes[i]);
                let message = x86_store_const(ref program, ref function, const_homes[i], X86Register.RBP, offset, slots, ref state, ref output);
                if (message.length() != 0) { return x86_lowering_error(message); }
            }
        }
        while (instruction_index < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[instruction_index]))];
            state.message = x86_lower_instruction(ref program, ref function, ref instruction, slots, scratch, frame_size, ref state, ref output, ref fixups, ref calls);
            if (state.message.length() != 0) {
                return x86_lowering_error("function '" + function.name + "', block '" + block.name + "', instruction " + instruction_index + " (opcode " + Int(instruction.opcode) + "): " + state.message);
            }
            if (instruction.result != NO_WIR_VALUE && x86_flag(cross, instruction.result)) {
                if (x86_wide_integer(ref program, instruction.type_id)) {
                    if (!x86_spill_wide_value(ref state, instruction.result, ref output)) {
                        return x86_lowering_error("the x86_64 lowering could not save a cross-block Int128 value");
                    }
                } else if (!x86_memory_value(ref program, instruction.type_id)) {
                    // write the defining value before its register can be reused
                    let register: X86Register = x86_register_for(ref state.registers, instruction.result);
                    let offset: Int = x86_stack_offset(ref stack, instruction.result);
                    let size: Int = x86_scalar_size(ref program, instruction.type_id);
                    if (register == X86Register.None || offset == 0 || !x86_store_scalar(ref output, register, X86Register.RBP, offset, size)) {
                        return x86_lowering_error("the x86_64 lowering could not save a cross-block value");
                    }
                }
            }

            x86_consume_instruction(ref state.registers.uses, instruction, state.position);
            x86_release_dead_registers(ref state.registers, state.position);
            x86_release_dead_spills(ref state.spills, ref state.registers.uses, state.position);

            state.position += 1;
            instruction_index += 1;
        }

        register_plan = state.registers;
        spill_plan = state.spills;
        carry_registers = x86_carry_registers_to_next(ref program, order, predecessors, block_index);
        position = state.position;
        block_index += 1;
    }

    if (!x86_patch_branches(ref output, offsets, fixups)) {
        return x86_lowering_error("the x86_64 lowering could not resolve a branch target");
    }

    return X86LoweringResult(bytes=output.bytes, errors=[], calls=calls, relocations=output.relocations, unwind=unwind);
}
