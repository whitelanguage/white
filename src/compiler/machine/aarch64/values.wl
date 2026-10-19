// src/compiler/machine/aarch64/values.wl
import * from "model.wl"
import * from "../../wir/model.wl"
import * from "encoder.wl"
import * from "allocator.wl"
import * from "memory.wl"
import * from "abi.wl"
import * from "fp.wl"
import * from "stack.wl"
import * from "types.wl"


func a64_spill_binding(
    ref program: WirModule,
    homes: A64StackIndex,
    ref values: A64ValueMap,
    ref output: A64CodeBuffer,
    index: Int
) -> Bool {
// Values get a stack home during frame layout, but writing every result there
// defeats the register cache. A dirty binding reaches its home only when the
// register is needed for something else or control leaves the current block.
    if (index < 0 || index >= values.bindings.length()) {
        return false;
    }

    let binding: A64RegisterBinding = values.bindings[index];
    if (!binding.dirty) {
        return true;
    }

    let home: A64StackSlot = a64_find_stack_slot(homes, binding.value);
    let value_index: Int = wir_id_index(UInt32(binding.value));
    if (home.value == NO_WIR_VALUE || value_index < 0 || value_index >= program.arena.values.length()) {
        return false;
    }

    if (binding.wide) {
        let pair: A64RegisterPair = a64_mapped_register_pair(ref values, binding.value);
        if (home.size != 16 || pair.low == A64Register.None || pair.high == A64Register.None ||
            !a64_store_integer_at(ref output, pair.low, A64Register.SP, home.offset, 64) ||
            !a64_store_integer_at(ref output, pair.high, A64Register.SP, home.offset + 8, 64)) {
            return false;
        }

        let low_index: Int = a64_binding_index(ref values, pair.low);
        let high_index: Int = a64_binding_index(ref values, pair.high);
        if (low_index < 0 || high_index < 0) {
            return false;
        }
        values.bindings[low_index] = A64RegisterBinding(
            register=pair.low,
            value=binding.value,
            held=false,
            dirty=false,
            wide=true
        );
        values.bindings[high_index] = A64RegisterBinding(
            register=pair.high,
            value=binding.value,
            held=false,
            dirty=false,
            wide=true
        );
        return true;
    }

    let type_id: WirTypeID = program.arena.values[value_index].type_id;
    let width: Int = a64_scalar_width(ref program, type_id);
    if (width == 0 || home.size != width / 8) {
        return false;
    }

    let saved: Bool = false;
    if (a64_scalar_float(ref program, type_id)) {
        saved = a64_store_float_at(ref output, binding.register, A64Register.SP, home.offset, width == 64);
    } else {
        saved = a64_store_integer_at(ref output, binding.register, A64Register.SP, home.offset, width);
    }
    if (!saved) {
        return false;
    }

    values.bindings[index] = A64RegisterBinding(
        register=binding.register,
        value=binding.value,
        held=binding.held,
        dirty=false,
        wide=false
    );
    return true;
}

func a64_alloc_register(
    ref program: WirModule,
    homes: A64StackIndex,
    ref values: A64ValueMap,
    ref output: A64CodeBuffer,
    floating: Bool
) -> A64Register {
    let index: Int = a64_select_register(ref program, ref values, floating);
    if (index < 0 || !a64_spill_binding(ref program, homes, ref values, ref output, index)) {
        return A64Register.None;
    }

    return a64_claim_register(ref values, index);
}

func a64_flush_registers(
    ref program: WirModule,
    homes: A64StackIndex,
    ref values: A64ValueMap,
    ref output: A64CodeBuffer
) -> Bool {
    let i: Int = 0;
    while (i < values.bindings.length()) {
        if (!a64_spill_binding(ref program, homes, ref values, ref output, i)) {
            return false;
        }
        i++;
    }
    return true;
}

func a64_spill_register(
    ref program: WirModule,
    homes: A64StackIndex,
    ref values: A64ValueMap,
    ref output: A64CodeBuffer,
    register: A64Register
) -> Bool {
    let index: Int = a64_binding_index(ref values, register);
    if (index < 0) {
        return true;
    }
    if (!a64_spill_binding(ref program, homes, ref values, ref output, index)) {
        return false;
    }

    a64_release_binding(ref values, index);
    return true;
}

func a64_save_aggregate_registers(
    ref output: A64CodeBuffer,
    home: A64StackSlot,
    first: Int,
    count: Int
) -> Bool {
    let i: Int = 0;
    while (i < count) {
        let incoming: A64Register = a64_argument_register(first + i, false);
        if (incoming == A64Register.None ||
            !a64_store_integer_at(ref output, incoming, A64Register.SP, home.offset + i * 8, 64)) {
            return false;
        }
        i++;
    }

    return true;
}

func a64_load_aggregate_registers(
    ref output: A64CodeBuffer,
    home: A64StackSlot,
    first: Int,
    count: Int
) -> Bool {
    let i: Int = 0;
    while (i < count) {
        let outgoing: A64Register = a64_argument_register(first + i, false);
        if (outgoing == A64Register.None ||
            !a64_load_integer_at(ref output, outgoing, A64Register.SP, home.offset + i * 8, 64)) {
            return false;
        }
        i++;
    }

    return true;
}

func a64_save_hfa_registers(ref output: A64CodeBuffer, home: A64StackSlot, first: Int, hfa: A64HFA) -> Bool {
    let i: Int = 0;
    while (i < hfa.count) {
        let incoming: A64Register = a64_argument_register(first + i, true);
        if (incoming == A64Register.None ||
            !a64_store_float_at(ref output, incoming, A64Register.SP, home.offset + i * (hfa.bits / 8), hfa.bits == 64)) {
            return false;
        }
        i++;
    }

    return true;
}

func a64_load_hfa_registers(ref output: A64CodeBuffer, home: A64StackSlot, first: Int, hfa: A64HFA) -> Bool {
    let i: Int = 0;
    while (i < hfa.count) {
        let destination: A64Register = a64_argument_register(first + i, true);
        if (destination == A64Register.None ||
            !a64_load_float_at(ref output, destination, A64Register.SP, home.offset + i * (hfa.bits / 8), hfa.bits == 64)) {
            return false;
        }
        i++;
    }

    return true;
}

func a64_value_symbol(ref program: WirModule, ref value: WirValue) -> String {
    let owner: Int = wir_id_index(value.owner);
    if (value.kind == WirValueKind.Global && owner >= 0 && owner < program.arena.globals.length()) {
        return program.arena.globals[owner].name;
    }
    if (value.kind == WirValueKind.Function && owner >= 0 && owner < program.arena.functions.length()) {
        return program.arena.functions[owner].name;
    }

    return "";
}

func a64_value_uses_got(ref program: WirModule, ref value: WirValue) -> Bool {
    let owner: Int = wir_id_index(value.owner);
    if (value.kind == WirValueKind.Global && owner >= 0 && owner < program.arena.globals.length()) {
        let linkage: WirLinkage = program.arena.globals[owner].linkage;
        return linkage == WirLinkage.Exported || linkage == WirLinkage.External;
    }
    if (value.kind == WirValueKind.Function && owner >= 0 && owner < program.arena.functions.length()) {
        let linkage: WirLinkage = program.arena.functions[owner].linkage;
        return linkage == WirLinkage.Exported || linkage == WirLinkage.External;
    }

    return false;
}

func a64_materialize_symbol(
    ref program: WirModule,
    ref value: WirValue,
    addend: Long,
    homes: A64StackIndex,
    ref values: A64ValueMap,
    ref output: A64CodeBuffer
) -> A64Register {
    let register: A64Register = a64_alloc_register(ref program, homes, ref values, ref output, false);
    if (register == A64Register.None) { return A64Register.None; }

    let symbol: String = a64_value_symbol(ref program, ref value);
    if (a64_value_uses_got(ref program, ref value)) {
        if (!a64_symbol_got_address(ref output, register, symbol)) { return A64Register.None; }

        if (addend > 0L && addend <= 4095L) {
            if (!a64_add_immediate(ref output, register, register, Int(addend), true)) { return A64Register.None; }
        } else if (addend < 0L && addend >= -4095L) {
            if (!a64_sub_immediate(ref output, register, register, Int(-addend), true)) { return A64Register.None; }
        } else if (addend != 0L) {
            let temporary: A64Register = a64_alloc_register(ref program, homes, ref values, ref output, false);
            if (temporary == A64Register.None || !a64_mov_immediate(ref output, temporary, UInt64(addend), true) ||
                !a64_add_register(ref output, register, register, temporary, true)) {
                return A64Register.None;
            }
        }
    } else if (!a64_symbol_address(ref output, register, symbol, addend)) {
        return A64Register.None;
    }

    return register;
}

func a64_materialize(
    ref program: WirModule,
    value_id: WirValueID,
    homes: A64StackIndex,
    ref values: A64ValueMap,
    ref output: A64CodeBuffer
) -> A64Register {
    let index: Int = wir_id_index(UInt32(value_id));
    if (index < 0 || index >= program.arena.values.length()) { return A64Register.None; }

    let ptr value: WirValue = ref program.arena.values[index];
    let mapped: A64Register = a64_mapped_register(ref values, value_id);
    if (mapped != A64Register.None) { return mapped; }

    let floating: Bool = a64_scalar_float(ref program, value.type_id);
    let width: Int = a64_scalar_width(ref program, value.type_id);
    let home: A64StackSlot = a64_find_stack_slot(homes, value_id);
    if (home.value != NO_WIR_VALUE) {
        let register: A64Register = a64_alloc_register(ref program, homes, ref values, ref output, floating);
        let loaded: Bool = false;
        if (floating) {
            loaded = a64_load_float_at(ref output, register, A64Register.SP, home.offset, width == 64);
        } else {
            loaded = a64_load_integer_at(ref output, register, A64Register.SP, home.offset, width);
        }
        if (register == A64Register.None || width == 0 || home.size != width / 8 || !loaded) {
            return A64Register.None;
        }

        if (!a64_bind_value(ref values, value_id, register, false)) { return A64Register.None; }
        return register;
    }

    if (value.kind == WirValueKind.Global || value.kind == WirValueKind.Function) {
        let register: A64Register = a64_materialize_symbol(ref program, ref program.arena.values[index], 0L, homes, ref values, ref output);
        if (register == A64Register.None || !a64_bind_value(ref values, value_id, register, false)) {
            return A64Register.None;
        }
        return register;
    }

    if (value.kind == WirValueKind.Constant) {
        let constant_index: Int = wir_id_index(value.owner);
        if (constant_index < 0 || constant_index >= program.arena.constants.length()) {
            return A64Register.None;
        }

        let ptr constant: WirConstant = ref program.arena.constants[constant_index];
        if (constant.kind == WirConstKind.Address) {
            let target_index: Int = wir_id_index(UInt32(constant.target));
            if (target_index < 0 || target_index >= program.arena.values.length()) {
                return A64Register.None;
            }
            let target: WirValue = program.arena.values[target_index];
            let register: A64Register = a64_materialize_symbol(
                ref program,
                ref target,
                constant.addend,
                homes,
                ref values,
                ref output
            );
            if (register == A64Register.None || !a64_bind_value(ref values, value_id, register, false)) {
                return A64Register.None;
            }
            return register;
        }
        if (constant.kind != WirConstKind.Zero) {
            return A64Register.None;
        }

        if (floating) {
            let bits: A64Register = a64_alloc_register(ref program, homes, ref values, ref output, false);
            let register: A64Register = a64_alloc_register(ref program, homes, ref values, ref output, true);
            if (bits == A64Register.None || register == A64Register.None ||
                !a64_mov_immediate(ref output, bits, 0UL, width == 64) ||
                !a64_float_from_bits(ref output, register, bits, width == 64)) {
                return A64Register.None;
            }
            if (!a64_bind_value(ref values, value_id, register, false)) { return A64Register.None; }
            return register;
        }

        let register: A64Register = a64_alloc_register(ref program, homes, ref values, ref output, false);
        if (register == A64Register.None || !a64_mov_immediate(ref output, register, 0UL, width == 64)) {
            return A64Register.None;
        }
        if (!a64_bind_value(ref values, value_id, register, false)) { return A64Register.None; }
        return register;
    }

    if (value.kind != WirValueKind.Integer && value.kind != WirValueKind.BoolValue && value.kind != WirValueKind.Null &&
        value.kind != WirValueKind.FloatValue) {
        return A64Register.None;
    }

    if (width == 0) { return A64Register.None; }

    if (floating) {
        let bits_register: A64Register = a64_alloc_register(ref program, homes, ref values, ref output, false);
        let register: A64Register = a64_alloc_register(ref program, homes, ref values, ref output, true);
        if (bits_register == A64Register.None || register == A64Register.None ||
            !a64_mov_immediate(ref output, bits_register, value.float_bits, width == 64) ||
            !a64_float_from_bits(ref output, register, bits_register, width == 64)) {
            return A64Register.None;
        }
        if (!a64_bind_value(ref values, value_id, register, false)) { return A64Register.None; }
        return register;
    }

    let register: A64Register = a64_alloc_register(ref program, homes, ref values, ref output, false);
    if (register == A64Register.None) { return register; }

    let bits: UInt64 = UInt64(value.integer & UInt128(18446744073709551615UL));
    if (!a64_mov_immediate(ref output, register, bits, width == 64)) {
        return A64Register.None;
    }

    if (!a64_bind_value(ref values, value_id, register, false)) { return A64Register.None; }
    return register;
}

func a64_materialize_address(
    ref program: WirModule,
    value_id: WirValueID,
    storage: A64StackIndex,
    homes: A64StackIndex,
    ref values: A64ValueMap,
    ref output: A64CodeBuffer
) -> A64Register {
// load the address consumed by field access, casts and calls

    // form StackAlloc pointers from frame offsets, loading a scalar home here
    // would read the allocation's contents and treat those bytes as an address.
    let mapped: A64Register = a64_mapped_register(ref values, value_id);
    if (mapped != A64Register.None) { return mapped; }

    let slot: A64StackSlot = a64_find_stack_slot(storage, value_id);
    if (slot.value != NO_WIR_VALUE) {
        let address: A64Register = a64_alloc_register(ref program, homes, ref values, ref output, false);
        if (address == A64Register.None || !a64_stack_address(ref output, address, slot.offset)) {
            return A64Register.None;
        }

        if (!a64_bind_value(ref values, value_id, address, false)) { return A64Register.None; }
        return address;
    }

    return a64_materialize(ref program, value_id, homes, ref values, ref output);
}

func a64_alloc_pair(
    ref program: WirModule,
    homes: A64StackIndex,
    ref values: A64ValueMap,
    ref output: A64CodeBuffer
) -> A64RegisterPair {
    let low: A64Register = a64_alloc_register(ref program, homes, ref values, ref output, false);
    let high: A64Register = a64_alloc_register(ref program, homes, ref values, ref output, false);

    return A64RegisterPair(low=low, high=high);
}

func a64_materialize_pair(
    ref program: WirModule,
    value_id: WirValueID,
    homes: A64StackIndex,
    ref values: A64ValueMap,
    ref output: A64CodeBuffer
) -> A64RegisterPair {
// 128-bit integers stay as a little-endian pair all the way through lowering.
    let index: Int = wir_id_index(UInt32(value_id));
    if (index < 0 || index >= program.arena.values.length()) {
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }

    let ptr value: WirValue = ref program.arena.values[index];
    if (a64_integer_width(ref program, value.type_id) != 128) {
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }

    let mapped: A64RegisterPair = a64_mapped_register_pair(ref values, value_id);
    if (mapped.low != A64Register.None && mapped.high != A64Register.None) {
        return mapped;
    }

    let pair: A64RegisterPair = a64_alloc_pair(ref program, homes, ref values, ref output);
    if (pair.low == A64Register.None || pair.high == A64Register.None) {
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }

    let home: A64StackSlot = a64_find_stack_slot(homes, value_id);
    if (home.value != NO_WIR_VALUE) {
        if (home.size != 16 ||
            !a64_load_integer_at(ref output, pair.low, A64Register.SP, home.offset, 64) ||
            !a64_load_integer_at(ref output, pair.high, A64Register.SP, home.offset + 8, 64)) {
            return A64RegisterPair(low=A64Register.None, high=A64Register.None);
        }

        if (!a64_bind_register_pair(ref values, value_id, pair.low, pair.high, false)) {
            return A64RegisterPair(low=A64Register.None, high=A64Register.None);
        }
        return pair;
    }

    if (value.kind == WirValueKind.Constant) {
        let constant_index: Int = wir_id_index(value.owner);
        if (constant_index >= 0 && constant_index < program.arena.constants.length() &&
            program.arena.constants[constant_index].kind == WirConstKind.Zero &&
            a64_mov_immediate(ref output, pair.low, 0UL, true) &&
            a64_mov_immediate(ref output, pair.high, 0UL, true)) {
            if (!a64_bind_register_pair(ref values, value_id, pair.low, pair.high, false)) {
                return A64RegisterPair(low=A64Register.None, high=A64Register.None);
            }
            return pair;
        }
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }
    if (value.kind != WirValueKind.Integer) {
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }

    let low_bits: UInt64 = UInt64(value.integer & UInt128(18446744073709551615UL));
    let high_bits: UInt64 = UInt64(value.integer >> UInt128(64U));
    if (!a64_mov_immediate(ref output, pair.low, low_bits, true) ||
        !a64_mov_immediate(ref output, pair.high, high_bits, true)) {
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }

    if (!a64_bind_register_pair(ref values, value_id, pair.low, pair.high, false)) {
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }

    return pair;
}

func a64_materialize_pair_into(
    ref program: WirModule,
    value_id: WirValueID,
    homes: A64StackIndex,
    destination: A64RegisterPair,
    ref output: A64CodeBuffer
) -> Bool {
    let index: Int = wir_id_index(UInt32(value_id));
    if (index < 0 || index >= program.arena.values.length() ||
        destination.low == A64Register.None || destination.high == A64Register.None) {
        return false;
    }

    let ptr value: WirValue = ref program.arena.values[index];
    if (a64_integer_width(ref program, value.type_id) != 128) {
        return false;
    }

    let home: A64StackSlot = a64_find_stack_slot(homes, value_id);
    if (home.value != NO_WIR_VALUE) {
        return home.size == 16 &&
               a64_load_integer_at(ref output, destination.low, A64Register.SP, home.offset, 64) &&
               a64_load_integer_at(ref output, destination.high, A64Register.SP, home.offset + 8, 64);
    }
    if (value.kind != WirValueKind.Integer) {
        return false;
    }

    return a64_mov_immediate(ref output, destination.low, UInt64(value.integer & UInt128(18446744073709551615UL)), true) &&
           a64_mov_immediate(ref output, destination.high, UInt64(value.integer >> UInt128(64U)), true);
}

func a64_save_pair(
    ref values: A64ValueMap,
    ref output: A64CodeBuffer,
    homes: A64StackIndex,
    value: WirValueID,
    pair: A64RegisterPair
) -> Bool {
    let home: A64StackSlot = a64_find_stack_slot(homes, value);
    if (home.value == NO_WIR_VALUE || home.size != 16 ||
        pair.low == A64Register.None || pair.high == A64Register.None) {
        return false;
    }

    let low_index: Int = a64_binding_index(ref values, pair.low);
    let high_index: Int = a64_binding_index(ref values, pair.high);
    if (low_index >= 0 && high_index >= 0 &&
        (values.bindings[low_index].value == NO_WIR_VALUE || values.bindings[low_index].value == value) &&
        (values.bindings[high_index].value == NO_WIR_VALUE || values.bindings[high_index].value == value)) {
        return a64_bind_register_pair(ref values, value, pair.low, pair.high, true);
    }

    return a64_store_integer_at(ref output, pair.low, A64Register.SP, home.offset, 64) &&
           a64_store_integer_at(ref output, pair.high, A64Register.SP, home.offset + 8, 64);
}

func a64_save_home(ref values: A64ValueMap, ref output: A64CodeBuffer, homes: A64StackIndex, value: WirValueID, register: A64Register, width: Int) -> Bool {
    let home: A64StackSlot = a64_find_stack_slot(homes, value);
    if (home.value == NO_WIR_VALUE || width == 0 || home.size != width / 8) { return false; }

    // ABI registers are outside the allocator bank and cannot carry a dirty
    // binding. Save those immediately, ordinary temporaries stay lazy.
    if (a64_binding_index(ref values, register) < 0) {
        if (a64_vec_code(register) >= 0) {
            return a64_store_float_at(ref output, register, A64Register.SP, home.offset, width == 64);
        }
        return a64_store_integer_at(ref output, register, A64Register.SP, home.offset, width);
    }

    return a64_bind_value(ref values, value, register, true);
}

func a64_store_value_at(
    ref program: WirModule,
    value_id: WirValueID,
    base: A64Register,
    offset: Int,
    storage: A64StackIndex,
    homes: A64StackIndex,
    layouts: Vector(WirTypeLayout),
    ref values: A64ValueMap,
    ref output: A64CodeBuffer
) -> Bool {
    let ptr value: WirValue = ref program.arena.values[wir_id_index(UInt32(value_id))];
    let ptr type: WirType = ref program.arena.types[wir_id_index(UInt32(value.type_id))];
    let width: Int = a64_memory_width(ref program, value.type_id);

    if (type.kind == WirTypeKind.Struct || type.kind == WirTypeKind.Array) {
        let layout: WirTypeLayout = layouts[wir_id_index(UInt32(value.type_id))];
        if (!layout.valid) {
            return false;
        }

        if (value.kind == WirValueKind.Constant) {
            let constant_index: Int = wir_id_index(value.owner);
            if (constant_index < 0 || constant_index >= program.arena.constants.length()) {
                return false;
            }

            let ptr constant: WirConstant = ref program.arena.constants[constant_index];
            if (constant.kind == WirConstKind.Zero) {
                return a64_zero_memory(ref output, base, offset, Int(layout.size));
            }
            if (constant.kind != WirConstKind.Aggregate ||
                !a64_zero_memory(ref output, base, offset, Int(layout.size))) {
                return false;
            }

            let stride: Int = 0;
            if (type.kind == WirTypeKind.Array) {
                let element_layout: WirTypeLayout = layouts[wir_id_index(UInt32(type.element))];
                if (!element_layout.valid || element_layout.size > 2147483647UL) {
                    return false;
                }
                stride = Int(element_layout.size);
            }

            let i: Int = 0;
            while (i < constant.elements.length()) {
                let member_offset: Int = i * stride;
                if (type.kind == WirTypeKind.Struct) {
                    if (i >= layout.field_offsets.length()) {
                        return false;
                    }
                    member_offset = Int(layout.field_offsets[i]);
                }
                if (!a64_store_value_at(
                    ref program,
                    constant.elements[i],
                    base,
                    offset + member_offset,
                    storage,
                    homes,
                    layouts,
                    ref values,
                    ref output
                )) {
                    return false;
                }
                i++;
            }
            return true;
        }

        let source: A64StackSlot = a64_find_stack_slot(homes, value_id);
        let temporary: A64Register = a64_alloc_register(ref program, homes, ref values, ref output, false);
        return source.value != NO_WIR_VALUE && temporary != A64Register.None &&
               a64_copy_memory(
                   ref output,
                   base,
                   offset,
                   A64Register.SP,
                   source.offset,
                   Int(layout.size),
                   temporary
               );
    }

    if (width == 128) {
        let pair: A64RegisterPair = a64_materialize_pair(ref program, value_id, homes, ref values, ref output);
        return pair.low != A64Register.None && pair.high != A64Register.None &&
               a64_store_integer_at(ref output, pair.low, base, offset, 64) &&
               a64_store_integer_at(ref output, pair.high, base, offset + 8, 64);
    }

    let source: A64Register = a64_materialize_address(
        ref program,
        value_id,
        storage,
        homes,
        ref values,
        ref output
    );
    if (source == A64Register.None || width == 0) {
        return false;
    }
    if (type.kind == WirTypeKind.FloatType) {
        return a64_store_float_at(ref output, source, base, offset, width == 64);
    }

    return a64_store_integer_at(ref output, source, base, offset, width);
}

func a64_load_value_at(
    ref program: WirModule,
    type_id: WirTypeID,
    result: WirValueID,
    base: A64Register,
    offset: Int,
    homes: A64StackIndex,
    layouts: Vector(WirTypeLayout),
    ref values: A64ValueMap,
    ref output: A64CodeBuffer
) -> Bool {
    let ptr type: WirType = ref program.arena.types[wir_id_index(UInt32(type_id))];
    let width: Int = a64_memory_width(ref program, type_id);

    if (type.kind == WirTypeKind.Struct || type.kind == WirTypeKind.Array) {
        let destination: A64StackSlot = a64_find_stack_slot(homes, result);
        let layout: WirTypeLayout = layouts[wir_id_index(UInt32(type_id))];
        let temporary: A64Register = a64_alloc_register(ref program, homes, ref values, ref output, false);
        return destination.value != NO_WIR_VALUE && layout.valid && temporary != A64Register.None &&
               a64_zero_memory(ref output, A64Register.SP, destination.offset, destination.size) &&
               a64_copy_memory(
                   ref output,
                   A64Register.SP,
                   destination.offset,
                   base,
                   offset,
                   Int(layout.size),
                   temporary
               );
    }

    if (width == 128) {
        let pair: A64RegisterPair = a64_alloc_pair(ref program, homes, ref values, ref output);
        return pair.low != A64Register.None && pair.high != A64Register.None &&
               a64_load_integer_at(ref output, pair.low, base, offset, 64) &&
               a64_load_integer_at(ref output, pair.high, base, offset + 8, 64) &&
               a64_save_pair(ref values, ref output, homes, result, pair);
    }

    let floating: Bool = type.kind == WirTypeKind.FloatType;
    let destination: A64Register = a64_alloc_register(ref program, homes, ref values, ref output, floating);
    let loaded: Bool = false;
    if (floating) {
        loaded = a64_load_float_at(ref output, destination, base, offset, width == 64);
    } else {
        loaded = a64_load_integer_at(ref output, destination, base, offset, width);
        if (loaded && type.kind == WirTypeKind.SignedInt && width < 32) {
            loaded = a64_extend_integer(ref output, destination, destination, width, true, false);
        }
    }

    return destination != A64Register.None && loaded &&
           a64_save_home(ref values, ref output, homes, result, destination, a64_scalar_width(ref program, type_id));
}
