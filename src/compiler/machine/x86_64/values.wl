// src/compiler/machine/x86_64/values.wl
import * from "model.wl"
import * from "../allocator.wl"
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


struct X86BlockState(
    accumulator: WirValueID,
    flags_value: WirValueID,
    flags_opcode: X86Opcode,
    registers: X86RegisterPlan,
    spills: X86SpillPlan,
    stack: X86StackIndex,
    layouts: Vector(WirTypeLayout),
    retain_function: WirFuncID,
    release_function: WirFuncID,
    null_function: WirFuncID,
    bounds_function: WirFuncID,
    return_pointer: Int,
    position: Int,
    message: String
)

struct X86RegisterResult(
    register: X86Register,
    message: String
)

func x86_parameter_index(ref function: WirFunction, value_id: WirValueID) -> Int {
    let i: Int = 0;
    while (i < function.parameters.length()) {
        if (function.parameters[i] == value_id) { return i; }
        i += 1;
    }
    return -1;
}

func x86_find_function(ref program: WirModule, name: String) -> WirFuncID {
    let i: Int = 0;
    while (i < program.arena.functions.length()) {
        if (program.arena.functions[i].name == name) {
            return WirFuncID(UInt32(i + 1));
        }
        i++;
    }
    return NO_WIR_FUNC;
}

func x86_runtime_failure(target: WirFuncID, ref output: X86CodeBuffer, ref calls: Vector(X86CallFixup)) -> Void {
    if (target == NO_WIR_FUNC) {
        x86_trap(ref output);
        return;
    }

    calls.append(X86CallFixup(offset=x86_call_rel32(ref output), target=target));
    x86_trap(ref output);
}

func x86_home_parameters(ref program: WirModule, function: WirFunction, stack: X86StackIndex, layouts: Vector(WirTypeLayout), ref output: X86CodeBuffer) -> Bool {
    let signature: WirType = program.arena.types[wir_id_index(UInt32(function.type_id))];
    let shift = 0;
    if (x86_indirect_return(ref program, signature.result, layouts, signature.abi)) { shift = 1; }

    if (x86_native_sysv_abi(signature.abi)) {
        let native_layout: X86SysVCallLayout = X86SysVCallLayout(hidden=X86Register.None, arguments=[], stack_size=0);
        x86_plan_sysv_call(ref program, signature, layouts, shift != 0, ref native_layout);
        let parameter_index: Int = 0;
        while (parameter_index < function.parameters.length()) {
            let parameter: WirValue = program.arena.values[wir_id_index(UInt32(function.parameters[parameter_index]))];
            let value_layout: WirTypeLayout = layouts[wir_id_index(UInt32(parameter.type_id))];
            let location: X86SysVValueLocation = native_layout.arguments[parameter_index];
            let offset: Int = x86_stack_offset(ref stack, function.parameters[parameter_index]);
            if (offset == 0 || !value_layout.valid) { return false; }

            if (location.stack_offset >= 0) {
                if (!x86_copy_memory(ref output, X86Register.RBP, offset, X86Register.RBP, 16 + location.stack_offset, Int(value_layout.size), X86Register.RAX)) {
                    return false;
                }
            } else {
                let first_size: Int = location.size;
                if (first_size > 8) { first_size = 8; }
                if (location.count > 0 && (location.first == X86Register.None ||
                    !x86_store_scalar(ref output, location.first, X86Register.RBP, offset, first_size))) {
                    return false;
                }
                if (location.count > 1) {
                    let second_size: Int = location.size - 8;
                    if (location.second == X86Register.None || second_size <= 0 ||
                        !x86_store_scalar(ref output, location.second, X86Register.RBP, offset + 8, second_size)) {
                        return false;
                    }
                }
            }
            parameter_index++;
        }
        return true;
    }

    let sysv_cursor: X86SysVArgCursor = X86SysVArgCursor(integer_index=0, float_index=0, stack_index=0);
    if (x86_is_sysv_abi() && shift != 0) {
        x86_sysv_arg(ref sysv_cursor, false);
    }
    let parameter_index: Int = 0;
    while (parameter_index < function.parameters.length()) {
        let parameter: WirValue = program.arena.values[wir_id_index(UInt32(function.parameters[parameter_index]))];
        let size: Int = x86_abi_size(ref program, parameter.type_id, layouts);
        if (x86_indirect_argument(ref program, parameter.type_id, layouts, signature.abi)) { size = 8; }
        let offset: Int = x86_stack_offset(ref stack, function.parameters[parameter_index]);
        if (offset == 0 || size == 0) { return false; }

        let position: Int = parameter_index + shift;
        let incoming: X86Register = X86Register.None;
        let stack_input: Int = -1;
        if (x86_is_sysv_abi()) {
            let floating: Bool = x86_scalar_float(ref program, parameter.type_id) &&
                !x86_indirect_argument(ref program, parameter.type_id, layouts, signature.abi);
            let location: X86ArgLocation = x86_sysv_arg(ref sysv_cursor, floating);
            incoming = location.register;
            stack_input = location.stack_offset;
        } else {
            incoming = x86_argument_register(position, x86_scalar_float(ref program, parameter.type_id));
        }
        if (incoming != X86Register.None) {
            if (!x86_store_scalar(ref output, incoming, X86Register.RBP, offset, size)) { return false; }
        } else {
            let incoming_offset: Int = stack_input;
            if (!x86_is_sysv_abi()) { incoming_offset = x86_stack_param_offset(position); }
            else {
                incoming_offset += 16;
            }
            if (incoming_offset < 0) { return false; }
            if (!x86_load_scalar(ref output, X86Register.RAX, X86Register.RBP, incoming_offset, size, x86_scalar_signed(ref program, parameter.type_id))) {
                return false;
            }
            if (!x86_store_scalar(ref output, X86Register.RAX, X86Register.RBP, offset, size)) {
                return false;
            }
        }
        parameter_index += 1;
    }
    // save every incoming register before the copy loop borrows RCX
    parameter_index = 0;
    while (parameter_index < function.parameters.length()) {
        let parameter: WirValue = program.arena.values[wir_id_index(UInt32(function.parameters[parameter_index]))];
        if (x86_indirect_argument(ref program, parameter.type_id, layouts, signature.abi)) {
            let offset = x86_stack_offset(ref stack, function.parameters[parameter_index]);
            let layout: WirTypeLayout = layouts[wir_id_index(UInt32(parameter.type_id))];
            x86_load_scalar(ref output, X86Register.R10, X86Register.RBP, offset, 8, false);
            if (!x86_copy_memory(ref output, X86Register.RBP, offset, X86Register.R10, 0, Int(layout.size), X86Register.RAX)) {
                return false;
            }
        }
        parameter_index++;
    }
    return true;
}

func x86_save_live_registers(ref program: WirModule, slots: Vector(X86StackSlot), operands: Vector(WirValueID), ref state: X86BlockState, ref output: X86CodeBuffer) -> String {
    let i: Int = 0;
    while (i < state.registers.bindings.length()) {
        let binding: X86RegisterBinding = state.registers.bindings[i];
        let needed: Bool = x86_next_use(ref state.registers.uses, binding.value, state.position) != X86_NO_NEXT_USE;
        let operand_index: Int = 0;
        while (binding.value != NO_WIR_VALUE && !needed && operand_index < operands.length()) {
            needed = operands[operand_index] == binding.value;
            operand_index++;
        }

        let pair: X86RegisterPair = x86_register_pair_for(ref state.registers, binding.value);
        if (pair.low != X86Register.None && pair.high != X86Register.None) {
            if (binding.register != pair.low) {
                i++;
                continue;
            }
            if (needed && !x86_spill_wide_value(ref state, binding.value, ref output)) {
                return "x86_64 cannot spill a 128-bit value before a call";
            }
            if (needed) { x86_forget_register_value(ref state.registers, binding.value); }
            i++;
            continue;
        }

        // argument setup may reuse scratch registers before all operands are read
        if (binding.value != NO_WIR_VALUE && needed) {
            if (machine_rematerializable(ref program, binding.value) || x86_stack_offset(ref state.stack, binding.value) != 0) {
                x86_clear_register(ref state.registers, binding.register);
            } else {
                let offset: Int = x86_claim_spill(ref state.spills, binding.value);
                if (offset == 0) {
                    return "x86_64 spill storage is exhausted before a call";
                }
                let ptr value: WirValue = ref program.arena.values[wir_id_index(UInt32(binding.value))];
                let size: Int = x86_scalar_size(ref program, value.type_id);
                if (size == 0 || !x86_store_scalar(ref output, binding.register, X86Register.RBP, offset, size)) {
                    return "x86_64 cannot spill this value before a call";
                }
                x86_clear_register(ref state.registers, binding.register);
            }
        }
        i += 1;
    }

    return "";
}

func x86_claim_register_spill(ref state: X86BlockState, value: WirValueID) -> Int {
    let offset: Int = x86_claim_spill(ref state.spills, value);
    if (offset != 0) { return offset; }

    // a reloaded SSA value can keep its old spill copy until another value needs the slot
    let i = 0;
    while (i < state.spills.bindings.length()) {
        let binding = state.spills.bindings[i];
        if (binding.value != value && x86_register_for(ref state.registers, binding.value) != X86Register.None) {
            x86_forget_spill_value(ref state.spills, binding.value);
            return x86_claim_spill(ref state.spills, value);
        }
        i++;
    }
    return 0;
}

func x86_prepare_register(ref program: WirModule, ref state: X86BlockState, choice: X86RegisterChoice, ref output: X86CodeBuffer) -> String {
    if (choice.register == X86Register.None) {
        return "no x86_64 register is available for this value";
    }
    if (choice.evicted == NO_WIR_VALUE) {
        return "";
    }

    let next_use: Int = x86_pending_use(ref state.registers.uses, choice.evicted, state.position);
    let pair: X86RegisterPair = x86_register_pair_for(ref state.registers, choice.evicted);
    if (pair.low != X86Register.None && pair.high != X86Register.None) {
        if (next_use != X86_NO_NEXT_USE && !x86_spill_wide_value(ref state, choice.evicted, ref output)) {
            return "x86_64 cannot spill this 128-bit value";
        }
        x86_forget_register_value(ref state.registers, choice.evicted);
        return "";
    }

    if (next_use == X86_NO_NEXT_USE || machine_rematerializable(ref program, choice.evicted) || x86_stack_offset(ref state.stack, choice.evicted) != 0) {
        x86_clear_register(ref state.registers, choice.register);
        return "";
    }

    if (x86_spill_offset(ref state.spills, choice.evicted) != 0) {
        x86_clear_register(ref state.registers, choice.register);
        return "";
    }

    let offset: Int = x86_claim_register_spill(ref state, choice.evicted);
    if (offset == 0) {
        return "x86_64 spill storage is exhausted";
    }

    let ptr value: WirValue = ref program.arena.values[wir_id_index(UInt32(choice.evicted))];
    let size: Int = x86_scalar_size(ref program, value.type_id);
    if (size == 0 || !x86_store_scalar(ref output, choice.register, X86Register.RBP, offset, size)) {
        return "x86_64 cannot spill this value";
    }
    x86_clear_register(ref state.registers, choice.register);

    return "";
}

func x86_bound_value(plan: X86RegisterPlan, register: X86Register) -> WirValueID {
    let i: Int = 0;
    while (i < plan.bindings.length()) {
        if (plan.bindings[i].register == register) {
            return plan.bindings[i].value;
        }
        i += 1;
    }
    return NO_WIR_VALUE;
}

func x86_prepare_fixed_register(ref program: WirModule, ref state: X86BlockState, register: X86Register, ref output: X86CodeBuffer) -> String {
    return x86_prepare_register(ref program, ref state, X86RegisterChoice(register=register, evicted=x86_bound_value(state.registers, register)), ref output);
}

func x86_prepare_clobbers(ref program: WirModule, ref state: X86BlockState, clobbers: UInt64, ref output: X86CodeBuffer) -> String {
// Fixed-register instructions used to save one or two registers at the
    // call site and leave the rest as an unwritten convention. Keep the mask
    // beside the lowering instead, so opening another allocator register does
    // not silently change the meaning of an old instruction sequence.
    let i: Int = 0;
    while (i < state.registers.bindings.length()) {
        let register: X86Register = state.registers.bindings[i].register;
        if ((clobbers & x86_register_clobber(register)) != 0UL) {
            let message: String = x86_prepare_fixed_register(ref program, ref state, register, ref output);
            if (message.length() != 0) { return message; }
        }
        i++;
    }
    return "";
}

func x86_prepare_memory_clobbers(ref program: WirModule, ref state: X86BlockState, size: Int, temporary: X86Register, ref output: X86CodeBuffer) -> String {
    if (temporary == X86Register.None) {
        return "no x86_64 register is available for the memory transfer";
    }
    let clobbers: UInt64 = x86_register_clobber(temporary);
    if (size > 64) { clobbers |= x86_register_clobber(X86Register.RCX); }
    return x86_prepare_clobbers(ref program, ref state, clobbers, ref output);
}

func x86_result_register_available(ref program: WirModule, ref state: X86BlockState, register: X86Register) -> Bool {
    let value: WirValueID = x86_bound_value(state.registers, register);
    if (value == NO_WIR_VALUE || x86_pending_use(ref state.registers.uses, value, state.position) == X86_NO_NEXT_USE) {
        return true;
    }
    return machine_rematerializable(ref program, value) || x86_stack_offset(ref state.stack, value) != 0 ||
           x86_spill_offset(ref state.spills, value) != 0;
}

func x86_choose_result_register(ref program: WirModule, ref state: X86BlockState, result: WirValueID, avoid: X86Register, floating: Bool) -> X86RegisterChoice {
    let preferred: X86Register = x86_preferred_register(ref state.registers.uses, result);
    if (preferred != X86Register.None && x86_allocatable_register(preferred) && x86_is_xmm(preferred) == floating &&
        preferred != avoid && x86_result_register_available(ref program, ref state, preferred)) {
        return X86RegisterChoice(register=preferred, evicted=x86_bound_value(state.registers, preferred));
    }
    return x86_choose_register_class(ref program, ref state.registers, state.position, avoid, floating);
}

func x86_choose_result_register_avoiding(ref program: WirModule, ref state: X86BlockState, result: WirValueID, first: X86Register, second: X86Register) -> X86RegisterChoice {
    let preferred: X86Register = x86_preferred_register(ref state.registers.uses, result);
    if (preferred != X86Register.None && preferred != first && preferred != second &&
        x86_allocatable_register(preferred) && !x86_is_xmm(preferred) &&
        x86_result_register_available(ref program, ref state, preferred)) {
        return X86RegisterChoice(register=preferred, evicted=x86_bound_value(state.registers, preferred));
    }
    return x86_choose_register_avoiding(ref program, ref state.registers, state.position, first, second);
}

func x86_bind_entry_parameters(ref program: WirModule, ref function: WirFunction, ref plan: X86RegisterPlan) -> Void {
    let i: Int = 0;
    let sysv_cursor: X86SysVArgCursor = X86SysVArgCursor(integer_index=0, float_index=0, stack_index=0);
    while (i < function.parameters.length()) {
        let value_id: WirValueID = function.parameters[i];
        let ptr value: WirValue = ref program.arena.values[wir_id_index(UInt32(value_id))];
        if (x86_scalar_size(ref program, value.type_id) != 0) {
            let incoming: X86Register = X86Register.None;
            if (x86_is_sysv_abi()) {
                let location: X86ArgLocation = x86_sysv_arg(ref sysv_cursor, x86_scalar_float(ref program, value.type_id));
                incoming = location.register;
            } else {
                incoming = x86_argument_register(i, x86_scalar_float(ref program, value.type_id));
            }
            if (incoming != X86Register.None) {
                x86_bind_register(ref plan, incoming, value_id);
            }
        }
        i++;
    }
}

func x86_overwrite_operand(ref program: WirModule, ref state: X86BlockState, register: X86Register, ref output: X86CodeBuffer) -> String {
// the in-place operand is already available, preserve it only for later uses
    let value: WirValueID = x86_bound_value(state.registers, register);
    if (x86_next_use(ref state.registers.uses, value, state.position) == X86_NO_NEXT_USE) {
        x86_clear_register(ref state.registers, register);
        return "";
    }
    return x86_prepare_fixed_register(ref program, ref state, register, ref output);
}

func x86_materialize_register_except(
    ref program: WirModule,
    ref function: WirFunction,
    value_id: WirValueID,
    slots: Vector(X86StackSlot),
    ref state: X86BlockState,
    avoid: X86Register,
    ref output: X86CodeBuffer
) -> X86RegisterResult {
    let allocated: X86Register = x86_register_for(ref state.registers, value_id);
    if (allocated != X86Register.None) {
        return X86RegisterResult(register=allocated, message="");
    }

    let ptr value: WirValue = ref program.arena.values[wir_id_index(UInt32(value_id))];
    let floating: Bool = x86_scalar_float(ref program, value.type_id);
    let choice: X86RegisterChoice = x86_choose_register_class(ref program, ref state.registers, state.position, avoid, floating);
    let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
    if (prepare_error.length() != 0) {
        return X86RegisterResult(register=X86Register.None, message=prepare_error);
    }

    let size: Int = x86_scalar_size(ref program, value.type_id);
    if (size == 0) {
        return X86RegisterResult(register=X86Register.None, message="the x86_64 allocator cannot materialize this value type");
    }
    let signed: Bool = x86_scalar_signed(ref program, value.type_id);
    let home: Int = x86_stack_offset(ref state.stack, value_id);
    let spill: Int = x86_spill_offset(ref state.spills, value_id);
    if (home != 0 && !machine_rematerializable(ref program, value_id)) {
        x86_load_scalar(ref output, choice.register, X86Register.RBP, home, size, signed);
    } else if (spill != 0) {
        x86_load_scalar(ref output, choice.register, X86Register.RBP, spill, size, signed);
    } else if (value.kind == WirValueKind.FloatValue || (floating && value.kind == WirValueKind.Constant && program.arena.constants[wir_id_index(value.owner)].kind == WirConstKind.Zero)) {
        let bits: UInt64 = value.float_bits;
        if (value.kind == WirValueKind.Constant) { bits = 0UL; }
        let integer: X86RegisterChoice = x86_choose_register_except(ref program, ref state.registers, state.position, avoid);
        let integer_error: String = x86_prepare_register(ref program, ref state, integer, ref output);
        if (integer_error.length() != 0) {
            return X86RegisterResult(register=X86Register.None, message=integer_error);
        }
        if (size == 8) {
            x86_mov_register_imm64(ref output, integer.register, bits);
        }
        else {
            x86_mov_register_imm32(ref output, integer.register, UInt32(bits));
        }
        x86_move_scalar(ref output, choice.register, integer.register, size);
    } else if (value.kind == WirValueKind.Integer) {
        if (size == 8) {
            x86_mov_register_imm64(ref output, choice.register, UInt64(value.integer));
        } else {
            x86_mov_register_imm32(ref output, choice.register, UInt32(value.integer));
        }

        x86_normalize_scalar(ref output, choice.register, size, signed);
    } else if (value.kind == WirValueKind.BoolValue || value.kind == WirValueKind.Null) {
        x86_mov_register_imm32(ref output, choice.register, UInt32(value.integer));
    } else if (value.kind == WirValueKind.Global || value.kind == WirValueKind.Function) {
        if (!x86_lea_symbol(ref output, choice.register, x86_address_symbol(ref program, value_id), 0L)) {
            return X86RegisterResult(register=X86Register.None, message="value has no linkable address symbol");
        }
    } else if (value.kind == WirValueKind.Constant) {
        let ptr constant: WirConstant = ref program.arena.constants[wir_id_index(value.owner)];
        if (constant.kind == WirConstKind.Zero) {
            x86_mov_register_imm32(ref output, choice.register, 0U);
        } else if (constant.kind == WirConstKind.Address) {
            if (!x86_lea_symbol(ref output, choice.register, x86_address_symbol(ref program, constant.target), constant.addend)) {
                return X86RegisterResult(register=X86Register.None, message="address constant exceeds the x86_64 RIP-relative displacement range");
            }
        } else {
            return X86RegisterResult(register=X86Register.None, message="aggregate constants cannot be materialized in an integer register");
        }
    } else if (value.kind == WirValueKind.Instruction && machine_rematerializable(ref program, value_id)) {
        let offset: Int = x86_stack_offset(ref state.stack, value_id);
        if (offset == 0 || !x86_lea(ref output, choice.register, X86Register.RBP, X86Register.None, 1, offset)) {
            return X86RegisterResult(register=X86Register.None, message="stack allocation has no addressable storage");
        }
    } else if (value.kind == WirValueKind.FunctionParameter) {
        let index: Int = x86_parameter_index(ref function, value_id);
        let incoming: X86Register = X86Register.None;
        let incoming_offset: Int = -1;
        if (x86_is_sysv_abi()) {
            let signature: WirType = program.arena.types[wir_id_index(UInt32(function.type_id))];
            let cursor: X86SysVArgCursor = X86SysVArgCursor(integer_index=0, float_index=0, stack_index=0);
            if (x86_indirect_return(ref program, signature.result, state.layouts, signature.abi)) {
                x86_sysv_arg(ref cursor, false);
            }
            let parameter_index: Int = 0;
            while (parameter_index <= index && parameter_index < signature.parameters.length()) {
                let parameter_type: WirTypeID = signature.parameters[parameter_index];
                let parameter_float: Bool = x86_scalar_float(ref program, parameter_type) &&
                    !x86_indirect_argument(ref program, parameter_type, state.layouts, signature.abi);
                let location: X86ArgLocation = x86_sysv_arg(ref cursor, parameter_float);
                if (parameter_index == index) {
                    incoming = location.register;
                    incoming_offset = location.stack_offset;
                }
                parameter_index += 1;
            }
        } else {
            incoming = x86_argument_register(index, floating);
        }
        if (incoming != X86Register.None) {
            x86_move_scalar(ref output, choice.register, incoming, size);
            x86_normalize_scalar(ref output, choice.register, size, signed);
        } else {
            if (!x86_is_sysv_abi()) { incoming_offset = x86_stack_param_offset(index); }
            else {
                incoming_offset += 16;
            }
            if (incoming_offset < 0) {
                return X86RegisterResult(register=X86Register.None, message="the x86_64 ABI has no stack location for this function parameter");
            }

            x86_load_scalar(ref output, choice.register, X86Register.RBP, incoming_offset, size, signed);
        }
    } else if (value.kind == WirValueKind.BlockParameter) {
        let offset: Int = x86_stack_offset(ref state.stack, value_id);
        if (offset == 0) {
            return X86RegisterResult(register=X86Register.None, message="block parameter has no assigned stack location");
        }

        x86_load_scalar(ref output, choice.register, X86Register.RBP, offset, size, signed);
    } else {
        return X86RegisterResult(register=X86Register.None, message="the x86_64 allocator cannot restore value %" + UInt32(value_id));
    }

    x86_bind_register(ref state.registers, choice.register, value_id);
    return X86RegisterResult(register=choice.register, message="");
}

func x86_materialize_register(
    ref program: WirModule,
    ref function: WirFunction,
    value_id: WirValueID,
    slots: Vector(X86StackSlot),
    ref state: X86BlockState,
    ref output: X86CodeBuffer
) -> X86RegisterResult {
    return x86_materialize_register_except(ref program, ref function, value_id, slots, ref state, X86Register.None, ref output);
}

func x86_store_value(
    ref program: WirModule,
    ref function: WirFunction,
    value_id: WirValueID,
    base: X86Register,
    offset: Int,
    slots: Vector(X86StackSlot),
    ref state: X86BlockState,
    ref output: X86CodeBuffer
) -> String {
    let ptr value: WirValue = ref program.arena.values[wir_id_index(UInt32(value_id))];
    // copies read the home, a cached Int128 pair may still hold its newest bits.
    if (x86_wide_integer(ref program, value.type_id) && !x86_spill_wide_value(ref state, value_id, ref output)) {
        return "cannot save a 128-bit integer before a memory copy";
    }

    if (!x86_memory_value(ref program, value.type_id)) {
        let stored: X86RegisterResult = x86_materialize_register_except(ref program, ref function, value_id, slots, ref state, base, ref output);
        if (stored.message.length() != 0) { return stored.message; }
        if (!x86_store_scalar(ref output, stored.register, base, offset, x86_scalar_size(ref program, value.type_id))) { return "unsupported aggregate member type"; }
        return "";
    }
    let layout: WirTypeLayout = state.layouts[wir_id_index(UInt32(value.type_id))];
    if (!layout.valid || layout.size > 2147483647UL) {
        return "aggregate has no addressable layout";
    }
    let temporary: X86RegisterChoice = x86_choose_register_except(ref program, ref state.registers, state.position, base);
    let prepare_error = x86_prepare_memory_clobbers(ref program, ref state, Int(layout.size), temporary.register, ref output);
    if (prepare_error.length() != 0) { return prepare_error; }
    let home = x86_stack_offset(ref state.stack, value_id);
    if (home != 0) {
        if (!x86_copy_memory(ref output, base, offset, X86Register.RBP, home, Int(layout.size), temporary.register)) {
            return "cannot encode aggregate copy";
        }
    } else if (x86_wide_integer(ref program, value.type_id) && value.kind == WirValueKind.Integer) {
        x86_mov_register_imm64(ref output, temporary.register, UInt64(value.integer & UInt128(18446744073709551615UL)));
        x86_store_scalar(ref output, temporary.register, base, offset, 8);
        x86_mov_register_imm64(ref output, temporary.register, UInt64(value.integer >> UInt128(64U)));
        x86_store_scalar(ref output, temporary.register, base, offset + 8, 8);
    } else if (value.kind == WirValueKind.Constant && program.arena.constants[wir_id_index(value.owner)].kind == WirConstKind.Zero) {
        if (!x86_zero_memory(ref output, base, offset, Int(layout.size), temporary.register)) {
            return "cannot encode aggregate zero initialization";
        }
    } else {
        return "aggregate value has no storage in the machine lowering";
    }
    return "";
}

func x86_store_const(ref program: WirModule, ref function: WirFunction, value_id: WirValueID, base: X86Register, offset: Int, slots: Vector(X86StackSlot), ref state: X86BlockState, ref output: X86CodeBuffer) -> String {
// initialize padding too, small aggregate ABIs load the complete bit pattern
    let value = program.arena.values[wir_id_index(UInt32(value_id))];
    if (!x86_aggregate_type(ref program, value.type_id)) {
        return x86_store_value(ref program, ref function, value_id, base, offset, slots, ref state, ref output);
    }

    let constant = program.arena.constants[wir_id_index(value.owner)];
    let type = program.arena.types[wir_id_index(UInt32(value.type_id))];
    let layout = state.layouts[wir_id_index(UInt32(value.type_id))];
    let temp = x86_choose_register_except(ref program, ref state.registers, state.position, base);

    let message = x86_prepare_memory_clobbers(ref program, ref state, Int(layout.size), temp.register, ref output);
    if (message.length() != 0) {
        return message;
    }

    if (!x86_zero_memory(ref output, base, offset, Int(layout.size), temp.register)) {
        return "cannot initialize aggregate constant storage";
    }

    if (constant.kind == WirConstKind.Zero) { return ""; }
    if (constant.kind == WirConstKind.Bytes) {
        if (UInt64(constant.bytes.length()) != layout.size) { return "byte constant length does not match its storage"; }
        for (let i = 0; i < constant.bytes.length(); i++) {
            x86_mov_register_imm32(ref output, temp.register, UInt32(constant.bytes[i]));
            if (!x86_store_scalar(ref output, temp.register, base, offset + i, 1)) {
                return "cannot initialize byte constant storage";
            }
        }
        return "";
    }
    if (constant.kind != WirConstKind.Aggregate) { return "expected an aggregate constant"; }

    let stride = 0;
    if (type.kind == WirTypeKind.Array) {
        stride = Int(state.layouts[wir_id_index(UInt32(type.element))].size);
    }

    for (let i = 0; i < constant.elements.length(); i++) {
        let member = i * stride;
        if (type.kind == WirTypeKind.Struct) {
            member = Int(layout.field_offsets[i]);
        }

        message = x86_store_const(ref program, ref function, constant.elements[i], base, offset + member, slots, ref state, ref output);
        if (message.length() != 0) {
            return message;
        }
    }

    return "";
}

func x86_materialize_abi_value(
    ref program: WirModule,
    ref function: WirFunction,
    value_id: WirValueID,
    slots: Vector(X86StackSlot),
    ref state: X86BlockState,
    ref output: X86CodeBuffer
) -> X86RegisterResult {
    let value = program.arena.values[wir_id_index(UInt32(value_id))];
    if (!x86_aggregate_type(ref program, value.type_id)) {
        return x86_materialize_register(ref program, ref function, value_id, slots, ref state, ref output);
    }
    let size = x86_abi_size(ref program, value.type_id, state.layouts);
    if (size == 0) {
        return X86RegisterResult(register=X86Register.None, message="indirect aggregate arguments are not implemented in the machine backend");
    }
    let choice: X86RegisterChoice = x86_choose_register(ref program, ref state.registers, state.position);
    let message = x86_prepare_register(ref program, ref state, choice, ref output);
    if (message.length() != 0) {
        return X86RegisterResult(register=X86Register.None, message=message);
    }
    let home = x86_stack_offset(ref state.stack, value_id);
    if (home != 0) {
        x86_load_scalar(ref output, choice.register, X86Register.RBP, home, size, false);
    } else if (value.kind == WirValueKind.Constant && program.arena.constants[wir_id_index(value.owner)].kind == WirConstKind.Zero) {
        x86_mov_register_imm32(ref output, choice.register, 0U);
    } else {
        return X86RegisterResult(register=X86Register.None, message="aggregate ABI operand has no storage");
    }
    // this is a transient bit-pattern load, not a scalar binding for the aggregate SSA value
    return X86RegisterResult(register=choice.register, message="");
}

func x86_load_wide_half(ref program: WirModule, value_id: WirValueID, high: Bool, destination: X86Register, ref state: X86BlockState, ref output: X86CodeBuffer) -> String {
    let ptr value: WirValue = ref program.arena.values[wir_id_index(UInt32(value_id))];
    if (!x86_wide_integer(ref program, value.type_id)) {
        return "value is not a 128-bit integer";
    }

    let pair: X86RegisterPair = x86_register_pair_for(ref state.registers, value_id);
    if (pair.low != X86Register.None && pair.high != X86Register.None) {
        let source: X86Register = pair.low;
        if high { source = pair.high; }
        if (source != destination) { x86_mov_register64(ref output, destination, source); }
        return "";
    }

    let offset = x86_stack_offset(ref state.stack, value_id);
    if (offset != 0) {
        if high { offset += 8; }
        if (!x86_load_scalar(ref output, destination, X86Register.RBP, offset, 8, false)) {
            return "cannot load a 128-bit integer half";
        }
        return "";
    }
    if (value.kind == WirValueKind.Integer) {
        let bits: UInt64 = UInt64(value.integer & UInt128(18446744073709551615UL));
        if high { bits = UInt64(value.integer >> UInt128(64U)); }
        x86_mov_register_imm64(ref output, destination, bits);
        return "";
    }
    if (value.kind == WirValueKind.Constant && program.arena.constants[wir_id_index(value.owner)].kind == WirConstKind.Zero) {
        x86_mov_register_imm32(ref output, destination, 0U);
        return "";
    }
    return "128-bit integer value has no storage";
}

func x86_store_wide_pair(value_id: WirValueID, low: X86Register, high: X86Register, ref state: X86BlockState, ref output: X86CodeBuffer) -> Bool {
    let offset = x86_stack_offset(ref state.stack, value_id);
    if (offset == 0) { return false; }

    if (x86_bind_register_pair(ref state.registers, value_id, low, high, true)) {
        return true;
    }

    return x86_store_scalar(ref output, low, X86Register.RBP, offset, 8) &&
           x86_store_scalar(ref output, high, X86Register.RBP, offset + 8, 8);
}

func x86_spill_wide_value(ref state: X86BlockState, value_id: WirValueID, ref output: X86CodeBuffer) -> Bool {
    let pair: X86RegisterPair = x86_register_pair_for(ref state.registers, value_id);
    if (pair.low == X86Register.None || pair.high == X86Register.None) {
        return true;
    }
    if (!x86_register_pair_dirty(ref state.registers, value_id)) {
        return true;
    }

    let offset: Int = x86_stack_offset(ref state.stack, value_id);
    if (offset == 0 ||
        !x86_store_scalar(ref output, pair.low, X86Register.RBP, offset, 8) ||
        !x86_store_scalar(ref output, pair.high, X86Register.RBP, offset + 8, 8)) {
        return false;
    }

    x86_mark_register_pair_clean(ref state.registers, value_id);
    return true;
}

func x86_prepare_wide_scratch(ref program: WirModule, ref state: X86BlockState, ref output: X86CodeBuffer, keep_result_pair: Bool = false) -> String {
    let clobbers: UInt64 = x86_register_clobber(X86Register.RCX) |
                             x86_register_clobber(X86Register.RDX) |
                             x86_register_clobber(X86Register.R8) |
                             x86_register_clobber(X86Register.R9) |
                             x86_register_clobber(X86Register.R11);
    if (!keep_result_pair) {
        clobbers |= x86_register_clobber(X86Register.RAX) |
                    x86_register_clobber(X86Register.R10);
    }
    return x86_prepare_clobbers(ref program, ref state, clobbers, ref output);
}

func x86_can_reuse_wide_result(ref state: X86BlockState, value: WirValueID) -> Bool {
    let pair: X86RegisterPair = x86_register_pair_for(ref state.registers, value);
    return pair.low == X86Register.RAX && pair.high == X86Register.R10 &&
           x86_next_use(ref state.registers.uses, value, state.position) == X86_NO_NEXT_USE;
}
