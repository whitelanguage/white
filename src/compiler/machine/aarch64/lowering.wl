// src/compiler/machine/aarch64/lowering.wl
import * from "model.wl"
import * from "encoder.wl"
import a64_argument_register, a64_pair_argument_index from "abi.wl"
import * from "../../wir/model.wl"
import wir_type_layouts from "../../wir/layout.wl"
import MachineSection, MachineSymbol from "../object.wl"
import MachineDataResult, MachineDataRelocation, machine_emit_globals from "../data.wl"


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

struct A64ValueMap(registers: Vector(A64Register), next_register: Int, next_float_register: Int)

struct A64RegisterPair(low: A64Register, high: A64Register)

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
    if (type.kind == WirTypeKind.FloatType && (type.bits == 32 || type.bits == 64)) { return type.bits; }
    if (type.kind != WirTypeKind.SignedInt && type.kind != WirTypeKind.UnsignedInt) { return 0; }
    if (type.bits <= 0 || type.bits > 64) { return 0; }
    if (type.bits <= 32) { return 32; }

    return 64;
}

func a64_integer_width(ref program: WirModule, type_id: WirTypeID) -> Int {
    let index: Int = wir_id_index(UInt32(type_id));
    if (index < 0 || index >= program.arena.types.length()) {
        return 0;
    }

    let type: WirType = program.arena.types[index];
    if (type.kind != WirTypeKind.SignedInt && type.kind != WirTypeKind.UnsignedInt) {
        return 0;
    }
    if (type.bits == 128) {
        return 128;
    }

    return a64_scalar_width(ref program, type_id);
}

func a64_integer_bits(ref program: WirModule, type_id: WirTypeID) -> Int {
    let index: Int = wir_id_index(UInt32(type_id));
    if (index < 0 || index >= program.arena.types.length()) {
        return 0;
    }

    let type: WirType = program.arena.types[index];
    if (type.kind != WirTypeKind.SignedInt && type.kind != WirTypeKind.UnsignedInt) {
        return 0;
    }

    return type.bits;
}

func a64_integer_signed(ref program: WirModule, type_id: WirTypeID) -> Bool {
    let index: Int = wir_id_index(UInt32(type_id));
    return index >= 0 && index < program.arena.types.length() &&
           program.arena.types[index].kind == WirTypeKind.SignedInt;
}

func a64_value_size(ref program: WirModule, type_id: WirTypeID) -> Int {
    let width: Int = a64_integer_width(ref program, type_id);
    if (width != 0) {
        return width / 8;
    }

    width = a64_scalar_width(ref program, type_id);
    if (width == 0) {
        return 0;
    }

    return width / 8;
}

func a64_scalar_float(ref program: WirModule, type_id: WirTypeID) -> Bool {
    let index: Int = wir_id_index(UInt32(type_id));
    return index >= 0 && index < program.arena.types.length() && program.arena.types[index].kind == WirTypeKind.FloatType;
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
        let bytes: Int = a64_value_size(ref program, program.arena.values[wir_id_index(UInt32(param))].type_id);
        if (bytes == 0) {
            return A64StackLayout(storage=[], homes=[], frame_size=0, message="AArch64 parameter home has an unsupported type");
        }

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
            let bytes: Int = a64_value_size(ref program, program.arena.values[wir_id_index(UInt32(param))].type_id);
            if (bytes == 0) {
                return A64StackLayout(storage=[], homes=[], frame_size=0, message="AArch64 block parameter home has an unsupported type");
            }

            size = a64_align(size, bytes);
            homes.append(A64StackSlot(value=param, offset=size, size=bytes));
            size += bytes;
            param_index++;
        }

        while (j < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[j]))];
            if (instruction.opcode == WirOpcode.StackAlloc) {
                let pointer: WirType = program.arena.types[wir_id_index(UInt32(instruction.type_id))];
                let bytes: Int = 0;
                if (pointer.kind == WirTypeKind.Pointer) { bytes = a64_value_size(ref program, pointer.element); }
                if (instruction.result == NO_WIR_VALUE || bytes == 0) {
                    return A64StackLayout(storage=[], homes=[], frame_size=0, message="AArch64 stack slot has an unsupported type");
                }

                size = a64_align(size, bytes);
                storage.append(A64StackSlot(value=instruction.result, offset=size, size=bytes));
                size += bytes;
            } else if (instruction.result != NO_WIR_VALUE) {
                let bytes: Int = a64_value_size(ref program, instruction.type_id);
                if (bytes != 0) {
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
// X9-X17 are caller-saved temporaries and do not overlap ABI argument registers.
    if (index == 0) { return A64Register.X9; }
    if (index == 1) { return A64Register.X10; }
    if (index == 2) { return A64Register.X11; }
    if (index == 3) { return A64Register.X12; }
    if (index == 4) { return A64Register.X13; }
    if (index == 5) { return A64Register.X14; }
    if (index == 6) { return A64Register.X15; }
    if (index == 7) { return A64Register.X16; }
    if (index == 8) { return A64Register.X17; }

    return A64Register.None;
}

func a64_float_work_register(index: Int) -> A64Register {
// V16-V22 are volatile under AAPCS64 and do not overlap argument registers.
    if (index == 0) { return A64Register.V16; }
    if (index == 1) { return A64Register.V17; }
    if (index == 2) { return A64Register.V18; }
    if (index == 3) { return A64Register.V19; }
    if (index == 4) { return A64Register.V20; }
    if (index == 5) { return A64Register.V21; }
    if (index == 6) { return A64Register.V22; }

    return A64Register.None;
}

func a64_new_value_map(value_count: Int) -> A64ValueMap {
    let registers: Vector(A64Register) = [];
    let i: Int = 0;

    while (i < value_count) {
        registers.append(A64Register.None);
        i++;
    }

    return A64ValueMap(registers=registers, next_register=0, next_float_register=0);
}

func a64_alloc_register(ref values: A64ValueMap, floating: Bool) -> A64Register {
    if floating {
        let register: A64Register = a64_float_work_register(values.next_float_register % 7);
        values.next_float_register++;
        return register;
    }

    let register: A64Register = a64_work_register(values.next_register % 9);
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

func a64_value_symbol(ref program: WirModule, value: WirValue) -> String {
    let owner: Int = wir_id_index(value.owner);
    if (value.kind == WirValueKind.Global && owner >= 0 && owner < program.arena.globals.length()) {
        return program.arena.globals[owner].name;
    }
    if (value.kind == WirValueKind.Function && owner >= 0 && owner < program.arena.functions.length()) {
        return program.arena.functions[owner].name;
    }

    return "";
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
    let floating: Bool = a64_scalar_float(ref program, value.type_id);
    let home: A64StackSlot = a64_find_stack_slot(homes, value_id);
    if (home.value != NO_WIR_VALUE) {
        let register: A64Register = a64_alloc_register(ref values, floating);
        let width: Int = a64_scalar_width(ref program, value.type_id);
        let loaded: Bool = false;
        if (floating) {
            loaded = a64_load_float(ref output, register, A64Register.SP, home.offset, width == 64);
        } else {
            loaded = a64_load_unsigned(ref output, register, A64Register.SP, home.offset, width == 64);
        }
        if (register == A64Register.None || width == 0 || home.size != width / 8 || !loaded) {
            return A64Register.None;
        }

        return register;
    }

    if (value.kind == WirValueKind.Global || value.kind == WirValueKind.Function) {
        let register: A64Register = a64_alloc_register(ref values, false);
        if (register == A64Register.None || !a64_symbol_address(ref output, register, a64_value_symbol(ref program, value), 0L)) {
            return A64Register.None;
        }

        return register;
    }

    if (value.kind != WirValueKind.Integer && value.kind != WirValueKind.BoolValue && value.kind != WirValueKind.Null &&
        value.kind != WirValueKind.FloatValue) {
        return A64Register.None;
    }

    let width: Int = a64_scalar_width(ref program, value.type_id);
    if (width == 0) { return A64Register.None; }

    if (floating) {
        let bits_register: A64Register = a64_alloc_register(ref values, false);
        let register: A64Register = a64_alloc_register(ref values, true);
        if (bits_register == A64Register.None || register == A64Register.None ||
            !a64_mov_immediate(ref output, bits_register, value.float_bits, width == 64) ||
            !a64_float_from_bits(ref output, register, bits_register, width == 64)) {
            return A64Register.None;
        }
        return register;
    }

    let register: A64Register = a64_alloc_register(ref values, false);
    if (register == A64Register.None) { return register; }

    let bits: UInt64 = UInt64(value.integer & UInt128(18446744073709551615UL));
    if (!a64_mov_immediate(ref output, register, bits, width == 64)) {
        return A64Register.None;
    }

    return register;
}

func a64_alloc_pair(ref values: A64ValueMap) -> A64RegisterPair {
    let low: A64Register = a64_alloc_register(ref values, false);
    let high: A64Register = a64_alloc_register(ref values, false);

    return A64RegisterPair(low=low, high=high);
}

func a64_materialize_pair(
    ref program: WirModule,
    value_id: WirValueID,
    homes: Vector(A64StackSlot),
    ref values: A64ValueMap,
    ref output: A64CodeBuffer
) -> A64RegisterPair {
// 128-bit integers stay as a little-endian pair all the way through lowering.
    let index: Int = wir_id_index(UInt32(value_id));
    if (index < 0 || index >= program.arena.values.length()) {
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }

    let value: WirValue = program.arena.values[index];
    if (a64_integer_width(ref program, value.type_id) != 128) {
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }

    let pair: A64RegisterPair = a64_alloc_pair(ref values);
    if (pair.low == A64Register.None || pair.high == A64Register.None) {
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }

    let home: A64StackSlot = a64_find_stack_slot(homes, value_id);
    if (home.value != NO_WIR_VALUE) {
        if (home.size != 16 ||
            !a64_load_unsigned(ref output, pair.low, A64Register.SP, home.offset, true) ||
            !a64_load_unsigned(ref output, pair.high, A64Register.SP, home.offset + 8, true)) {
            return A64RegisterPair(low=A64Register.None, high=A64Register.None);
        }

        return pair;
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

    return pair;
}

func a64_materialize_pair_into(
    ref program: WirModule,
    value_id: WirValueID,
    homes: Vector(A64StackSlot),
    destination: A64RegisterPair,
    ref output: A64CodeBuffer
) -> Bool {
    let index: Int = wir_id_index(UInt32(value_id));
    if (index < 0 || index >= program.arena.values.length() ||
        destination.low == A64Register.None || destination.high == A64Register.None) {
        return false;
    }

    let value: WirValue = program.arena.values[index];
    if (a64_integer_width(ref program, value.type_id) != 128) {
        return false;
    }

    let home: A64StackSlot = a64_find_stack_slot(homes, value_id);
    if (home.value != NO_WIR_VALUE) {
        return home.size == 16 &&
               a64_load_unsigned(ref output, destination.low, A64Register.SP, home.offset, true) &&
               a64_load_unsigned(ref output, destination.high, A64Register.SP, home.offset + 8, true);
    }
    if (value.kind != WirValueKind.Integer) {
        return false;
    }

    return a64_mov_immediate(ref output, destination.low, UInt64(value.integer & UInt128(18446744073709551615UL)), true) &&
           a64_mov_immediate(ref output, destination.high, UInt64(value.integer >> UInt128(64U)), true);
}

func a64_save_pair(ref output: A64CodeBuffer, homes: Vector(A64StackSlot), value: WirValueID, pair: A64RegisterPair) -> Bool {
    let home: A64StackSlot = a64_find_stack_slot(homes, value);
    if (home.value == NO_WIR_VALUE || home.size != 16 ||
        pair.low == A64Register.None || pair.high == A64Register.None) {
        return false;
    }

    return a64_store_unsigned(ref output, pair.low, A64Register.SP, home.offset, true) &&
           a64_store_unsigned(ref output, pair.high, A64Register.SP, home.offset + 8, true);
}

func a64_wide_binary(ref output: A64CodeBuffer, opcode: WirOpcode, destination: A64RegisterPair, left: A64RegisterPair, right: A64RegisterPair) -> Bool {
    if (opcode == WirOpcode.Add) {
        return a64_add_sub_flags(ref output, destination.low, left.low, right.low, false) &&
               a64_add_sub_carry(ref output, destination.high, left.high, right.high, false);
    }
    if (opcode == WirOpcode.Subtract) {
        return a64_add_sub_flags(ref output, destination.low, left.low, right.low, true) &&
               a64_add_sub_carry(ref output, destination.high, left.high, right.high, true);
    }

    let operation: Int = -1;
    if (opcode == WirOpcode.BitAnd) { operation = 0; }
    if (opcode == WirOpcode.BitOr) { operation = 1; }
    if (opcode == WirOpcode.BitXor) { operation = 2; }
    if (operation < 0) {
        return false;
    }

    return a64_logical_register(ref output, destination.low, left.low, right.low, operation, true) &&
           a64_logical_register(ref output, destination.high, left.high, right.high, operation, true);
}

func a64_wide_multiply(ref output: A64CodeBuffer, destination: A64RegisterPair, left: A64RegisterPair, right: A64RegisterPair, temporary: A64Register) -> Bool {
// Only the low 128 bits survive. The two cross products contribute their low
// words to the high half, UMULH supplies the missing half of low * low.
    if (!a64_multiply_register(ref output, destination.low, left.low, right.low, true) ||
        !a64_multiply_high_unsigned(ref output, destination.high, left.low, right.low) ||
        !a64_multiply_register(ref output, temporary, left.high, right.low, true) ||
        !a64_add_register(ref output, destination.high, destination.high, temporary, true) ||
        !a64_multiply_register(ref output, temporary, left.low, right.high, true)) {
        return false;
    }

    return a64_add_register(ref output, destination.high, destination.high, temporary, true);
}

func a64_apply_wide_sign(ref output: A64CodeBuffer, value: A64RegisterPair, mask: A64Register) -> Bool {
    return a64_logical_register(ref output, value.low, value.low, mask, 2, true) &&
           a64_logical_register(ref output, value.high, value.high, mask, 2, true) &&
           a64_add_sub_flags(ref output, value.low, value.low, mask, true) &&
           a64_add_sub_carry(ref output, value.high, value.high, mask, true);
}

func a64_wide_divide(ref output: A64CodeBuffer, signed: Bool, remainder: Bool) -> A64RegisterPair {
// X0:X1 starts as the dividend and becomes the quotient. X4:X5 is the
// remainder. Keeping the loop in emitted code avoids unrolling 128 rounds.
    let quotient: A64RegisterPair = A64RegisterPair(low=A64Register.X0, high=A64Register.X1);
    let divisor: A64RegisterPair = A64RegisterPair(low=A64Register.X2, high=A64Register.X3);
    let rest: A64RegisterPair = A64RegisterPair(low=A64Register.X4, high=A64Register.X5);
    let counter: A64Register = A64Register.X6;
    let bit: A64Register = A64Register.X7;
    let temporary: A64Register = A64Register.X8;
    let one: A64Register = A64Register.X9;
    let quotient_sign: A64Register = A64Register.X10;
    let remainder_sign: A64Register = A64Register.X11;
    let divisor_sign: A64Register = A64Register.X12;

    if (!a64_mov_immediate(ref output, temporary, 63UL, true)) {
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }
    if signed {
        if (!a64_shift_register(ref output, remainder_sign, quotient.high, temporary, 1, true) ||
            !a64_shift_register(ref output, divisor_sign, divisor.high, temporary, 1, true) ||
            !a64_logical_register(ref output, quotient_sign, divisor_sign, remainder_sign, 2, true) ||
            !a64_apply_wide_sign(ref output, quotient, remainder_sign) ||
            !a64_apply_wide_sign(ref output, divisor, divisor_sign)) {
            return A64RegisterPair(low=A64Register.None, high=A64Register.None);
        }
    }

    if (!a64_mov_immediate(ref output, rest.low, 0UL, true) ||
        !a64_mov_immediate(ref output, rest.high, 0UL, true) ||
        !a64_mov_immediate(ref output, counter, 128UL, true) ||
        !a64_mov_immediate(ref output, one, 1UL, true)) {
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }

    let loop: Int = output.bytes.length();
    if (!a64_mov_immediate(ref output, temporary, 63UL, true) ||
        !a64_shift_register(ref output, bit, quotient.high, temporary, 2, true) ||
        !a64_shift_register(ref output, quotient.high, quotient.high, one, 0, true) ||
        !a64_shift_register(ref output, temporary, quotient.low, temporary, 2, true) ||
        !a64_logical_register(ref output, quotient.high, quotient.high, temporary, 1, true) ||
        !a64_shift_register(ref output, quotient.low, quotient.low, one, 0, true) ||
        !a64_mov_immediate(ref output, temporary, 63UL, true) ||
        !a64_shift_register(ref output, temporary, rest.low, temporary, 2, true) ||
        !a64_shift_register(ref output, rest.high, rest.high, one, 0, true) ||
        !a64_logical_register(ref output, rest.high, rest.high, temporary, 1, true) ||
        !a64_shift_register(ref output, rest.low, rest.low, one, 0, true) ||
        !a64_logical_register(ref output, rest.low, rest.low, bit, 1, true) ||
        !a64_compare_register(ref output, rest.high, divisor.high, true)) {
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }

    let subtract_high: Int = output.bytes.length();
    if (!a64_conditional_branch(ref output, 0, A64Condition.UnsignedHigher)) {
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }
    let skip_high: Int = output.bytes.length();
    if (!a64_conditional_branch(ref output, 0, A64Condition.CarryClear) ||
        !a64_compare_register(ref output, rest.low, divisor.low, true)) {
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }
    let skip_low: Int = output.bytes.length();
    if (!a64_conditional_branch(ref output, 0, A64Condition.CarryClear) ||
        !a64_patch_branch(ref output, subtract_high, output.bytes.length(), A64Condition.UnsignedHigher, true) ||
        !a64_add_sub_flags(ref output, rest.low, rest.low, divisor.low, true) ||
        !a64_add_sub_carry(ref output, rest.high, rest.high, divisor.high, true) ||
        !a64_logical_register(ref output, quotient.low, quotient.low, one, 1, true)) {
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }

    let next: Int = output.bytes.length();
    if (!a64_patch_branch(ref output, skip_high, next, A64Condition.CarryClear, true) ||
        !a64_patch_branch(ref output, skip_low, next, A64Condition.CarryClear, true) ||
        !a64_add_sub_flags(ref output, counter, counter, one, true) ||
        !a64_conditional_branch(ref output, loop - output.bytes.length(), A64Condition.NotEqual)) {
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }

    if signed {
        if (!a64_apply_wide_sign(ref output, quotient, quotient_sign) ||
            !a64_apply_wide_sign(ref output, rest, remainder_sign)) {
            return A64RegisterPair(low=A64Register.None, high=A64Register.None);
        }
    }
    if remainder {
        return rest;
    }

    return quotient;
}

func a64_wide_unary(ref output: A64CodeBuffer, opcode: WirOpcode, destination: A64RegisterPair, source: A64RegisterPair, temporary: A64Register) -> Bool {
    if (!a64_invert_register(ref output, destination.low, source.low, true) ||
        !a64_invert_register(ref output, destination.high, source.high, true)) {
        return false;
    }
    if (opcode == WirOpcode.Not) {
        return true;
    }
    if (opcode != WirOpcode.Negate || temporary == A64Register.None ||
        !a64_mov_immediate(ref output, temporary, 1UL, true)) {
        return false;
    }

    return a64_add_sub_flags(ref output, destination.low, destination.low, temporary, false) &&
           a64_add_sub_carry(ref output, destination.high, destination.high, A64Register.ZR, false);
}

func a64_wide_compare(ref output: A64CodeBuffer, opcode: WirOpcode, destination: A64Register, first: A64Register, second: A64Register, left: A64RegisterPair, right: A64RegisterPair) -> Bool {
    if (opcode == WirOpcode.Equal || opcode == WirOpcode.NotEqual) {
        let condition: A64Condition = A64Condition.Equal;
        let operation: Int = 0;
        if (opcode == WirOpcode.NotEqual) {
            condition = A64Condition.NotEqual;
            operation = 1;
        }

        return a64_compare_register(ref output, left.low, right.low, true) &&
               a64_set_condition(ref output, destination, condition) &&
               a64_compare_register(ref output, left.high, right.high, true) &&
               a64_set_condition(ref output, first, condition) &&
               a64_logical_register(ref output, destination, destination, first, operation, false);
    }

    let high_condition: A64Condition = A64Condition.Never;
    let low_condition: A64Condition = A64Condition.Never;
    if (opcode == WirOpcode.SignedLess) { high_condition = A64Condition.SignedLess; low_condition = A64Condition.CarryClear; }
    if (opcode == WirOpcode.SignedLessEqual) { high_condition = A64Condition.SignedLess; low_condition = A64Condition.UnsignedLowerOrSame; }
    if (opcode == WirOpcode.SignedGreater) { high_condition = A64Condition.SignedGreater; low_condition = A64Condition.UnsignedHigher; }
    if (opcode == WirOpcode.SignedGreaterEqual) { high_condition = A64Condition.SignedGreater; low_condition = A64Condition.CarrySet; }
    if (opcode == WirOpcode.UnsignedLess) { high_condition = A64Condition.CarryClear; low_condition = A64Condition.CarryClear; }
    if (opcode == WirOpcode.UnsignedLessEqual) { high_condition = A64Condition.CarryClear; low_condition = A64Condition.UnsignedLowerOrSame; }
    if (opcode == WirOpcode.UnsignedGreater) { high_condition = A64Condition.UnsignedHigher; low_condition = A64Condition.UnsignedHigher; }
    if (opcode == WirOpcode.UnsignedGreaterEqual) { high_condition = A64Condition.UnsignedHigher; low_condition = A64Condition.CarrySet; }
    if (high_condition == A64Condition.Never) {
        return false;
    }

    return a64_compare_register(ref output, left.high, right.high, true) &&
           a64_set_condition(ref output, destination, high_condition) &&
           a64_set_condition(ref output, first, A64Condition.Equal) &&
           a64_compare_register(ref output, left.low, right.low, true) &&
           a64_set_condition(ref output, second, low_condition) &&
           a64_logical_register(ref output, second, second, first, 0, false) &&
           a64_logical_register(ref output, destination, destination, second, 1, false);
}

func a64_wide_shift(ref output: A64CodeBuffer, opcode: WirOpcode, destination: A64RegisterPair, source: A64RegisterPair, amount: A64Register, count: A64Register, work: A64Register, cross: A64Register) -> Bool {
// The language masks a 128-bit shift count to seven bits. Keep the two paths
// short, shifts below 64 combine both words, larger shifts move one word only.
    if (!a64_mov_register(ref output, destination.low, source.low, true) ||
        !a64_mov_register(ref output, destination.high, source.high, true) ||
        !a64_mov_immediate(ref output, work, 127UL, true) ||
        !a64_logical_register(ref output, count, amount, work, 0, true) ||
        !a64_compare_zero(ref output, count, true)) {
        return false;
    }

    let zero: Int = output.bytes.length();
    if (!a64_conditional_branch(ref output, 0, A64Condition.Equal) ||
        !a64_mov_immediate(ref output, work, 64UL, true) ||
        !a64_compare_register(ref output, count, work, true)) {
        return false;
    }

    let large: Int = output.bytes.length();
    if (!a64_conditional_branch(ref output, 0, A64Condition.CarrySet) ||
        !a64_sub_register(ref output, work, work, count, true)) {
        return false;
    }

    if (opcode == WirOpcode.ShiftLeft) {
        if (!a64_shift_register(ref output, destination.high, source.high, count, 0, true) ||
            !a64_shift_register(ref output, cross, source.low, work, 2, true) ||
            !a64_logical_register(ref output, destination.high, destination.high, cross, 1, true) ||
            !a64_shift_register(ref output, destination.low, source.low, count, 0, true)) {
            return false;
        }
    } else {
        let high_shift: Int = 2;
        if (opcode == WirOpcode.SignedShiftRight) { high_shift = 1; }
        if (!a64_shift_register(ref output, destination.low, source.low, count, 2, true) ||
            !a64_shift_register(ref output, cross, source.high, work, 0, true) ||
            !a64_logical_register(ref output, destination.low, destination.low, cross, 1, true) ||
            !a64_shift_register(ref output, destination.high, source.high, count, high_shift, true)) {
            return false;
        }
    }

    let done: Int = output.bytes.length();
    if (!a64_branch(ref output, 0, false) ||
        !a64_patch_branch(ref output, large, output.bytes.length(), A64Condition.CarrySet, true) ||
        !a64_mov_immediate(ref output, work, 63UL, true) ||
        !a64_logical_register(ref output, count, count, work, 0, true)) {
        return false;
    }

    if (opcode == WirOpcode.ShiftLeft) {
        if (!a64_shift_register(ref output, destination.high, source.low, count, 0, true) ||
            !a64_mov_immediate(ref output, destination.low, 0UL, true)) {
            return false;
        }
    } else {
        let low_shift: Int = 2;
        if (opcode == WirOpcode.SignedShiftRight) { low_shift = 1; }
        if (!a64_shift_register(ref output, destination.low, source.high, count, low_shift, true)) {
            return false;
        }
        if (opcode == WirOpcode.SignedShiftRight) {
            if (!a64_mov_immediate(ref output, work, 63UL, true) ||
                !a64_shift_register(ref output, destination.high, source.high, work, 1, true)) {
                return false;
            }
        } else if (!a64_mov_immediate(ref output, destination.high, 0UL, true)) {
            return false;
        }
    }

    let end: Int = output.bytes.length();
    return a64_patch_branch(ref output, zero, end, A64Condition.Equal, true) &&
           a64_patch_branch(ref output, done, end, A64Condition.Always, false);
}

func a64_save_home(ref output: A64CodeBuffer, homes: Vector(A64StackSlot), value: WirValueID, register: A64Register, width: Int) -> Bool {
    let home: A64StackSlot = a64_find_stack_slot(homes, value);
    if (home.value == NO_WIR_VALUE || width == 0 || home.size != width / 8) { return false; }

    if (a64_vec_code(register) >= 0) {
        return a64_store_float(ref output, register, A64Register.SP, home.offset, width == 64);
    }

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

func a64_is_integer_division(opcode: WirOpcode) -> Bool {
    return opcode == WirOpcode.SignedDivide || opcode == WirOpcode.UnsignedDivide ||
           opcode == WirOpcode.SignedRemainder || opcode == WirOpcode.UnsignedRemainder;
}

func a64_is_float_comparison(opcode: WirOpcode) -> Bool {
    return opcode == WirOpcode.Equal || opcode == WirOpcode.NotEqual ||
           opcode == WirOpcode.FloatLess || opcode == WirOpcode.FloatLessEqual ||
           opcode == WirOpcode.FloatGreater || opcode == WirOpcode.FloatGreaterEqual;
}

func a64_float_condition(opcode: WirOpcode) -> A64Condition {
// FCMP's unordered flags make these conditions match WIR's ordered relations.
// NotEqual is unordered-or-not-equal, the same rule used by the LLVM backend.
    if (opcode == WirOpcode.Equal) { return A64Condition.Equal; }
    if (opcode == WirOpcode.NotEqual) { return A64Condition.NotEqual; }
    if (opcode == WirOpcode.FloatLess) { return A64Condition.Minus; }
    if (opcode == WirOpcode.FloatLessEqual) { return A64Condition.UnsignedLowerOrSame; }
    if (opcode == WirOpcode.FloatGreater) { return A64Condition.SignedGreater; }
    if (opcode == WirOpcode.FloatGreaterEqual) { return A64Condition.SignedGreaterOrEqual; }

    return A64Condition.Never;
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

func a64_is_float_binary(opcode: WirOpcode) -> Bool {
    return opcode == WirOpcode.Add || opcode == WirOpcode.Subtract ||
           opcode == WirOpcode.Multiply || opcode == WirOpcode.FloatDivide;
}

func a64_emit_float_binary(ref output: A64CodeBuffer, opcode: WirOpcode, destination: A64Register, left: A64Register, right: A64Register, double: Bool) -> Bool {
    let operation: Int = -1;
    if (opcode == WirOpcode.Add) { operation = 0; }
    if (opcode == WirOpcode.Subtract) { operation = 1; }
    if (opcode == WirOpcode.Multiply) { operation = 2; }
    if (opcode == WirOpcode.FloatDivide) { operation = 3; }
    if (operation < 0) { return false; }

    return a64_float_binary(ref output, destination, left, right, operation, double);
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
        let parameter_type: WirTypeID = program.arena.values[wir_id_index(UInt32(parameter))].type_id;
        let width: Int = a64_integer_width(ref program, parameter_type);
        if (width == 128) {
            let pair: A64RegisterPair = a64_materialize_pair(ref program, argument, homes, ref values, ref output);
            if (!a64_save_pair(ref output, homes, parameter, pair)) {
                return false;
            }

            i++;
            continue;
        }

        width = a64_scalar_width(ref program, parameter_type);
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
    let output: A64CodeBuffer = a64_new_code_buffer();
    let values: A64ValueMap = a64_new_value_map(program.arena.values.length());
    let offsets: Vector(A64BlockOffset) = [];
    let fixups: Vector(A64BranchFixup) = [];
    let layouts: Vector(WirTypeLayout) = wir_type_layouts(program);
    let stack: A64StackLayout = a64_stack_layout(ref program, ref function);
    if (stack.message.length() != 0) { return a64_lowering_error(stack.message); }

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

    let integer_argument: Int = 0;
    let float_argument: Int = 0;
    i = 0;
    while (i < function.parameters.length()) {
        let parameter: WirValueID = function.parameters[i];
        let value: WirValue = program.arena.values[wir_id_index(UInt32(parameter))];
        let width: Int = a64_integer_width(ref program, value.type_id);
        let floating: Bool = a64_scalar_float(ref program, value.type_id);

        if (width == 128) {
            let pair_index: Int = a64_pair_argument_index(integer_argument);
            if (pair_index < 0 || !a64_save_pair(
                ref output,
                stack.homes,
                parameter,
                A64RegisterPair(
                    low=a64_argument_register(pair_index, false),
                    high=a64_argument_register(pair_index + 1, false)
                )
            )) {
                return a64_lowering_error("cannot save an AArch64 128-bit argument pair");
            }

            integer_argument = pair_index + 2;
            i++;
            continue;
        }

        width = a64_scalar_width(ref program, value.type_id);
        let argument_index: Int = integer_argument;
        if floating { argument_index = float_argument; }
        if (width == 0) {
            return a64_lowering_error("initial AArch64 lowering only supports scalar parameters");
        }
        let incoming: A64Register = a64_argument_register(argument_index, floating);
        if (incoming == A64Register.None || !a64_save_home(ref output, stack.homes, parameter, incoming, width)) {
            return a64_lowering_error("cannot save an AArch64 argument register");
        }
        if floating { float_argument++; } else { integer_argument++; }
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
                let floating: Bool = a64_scalar_float(ref program, instruction.type_id);
                let width: Int = a64_integer_width(ref program, instruction.type_id);
                let base: A64Register = A64Register.SP;
                let offset: Int = slot.offset;
                if (slot.value == NO_WIR_VALUE) {
                    base = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                    offset = 0;
                }

                if (width == 128) {
                    let pair: A64RegisterPair = a64_alloc_pair(ref values);
                    if (base == A64Register.None || pair.low == A64Register.None || pair.high == A64Register.None ||
                        !a64_load_unsigned(ref output, pair.low, base, offset, true) ||
                        !a64_load_unsigned(ref output, pair.high, base, offset + 8, true) ||
                        !a64_save_pair(ref output, stack.homes, instruction.result, pair)) {
                        return a64_lowering_error("cannot encode AArch64 128-bit load");
                    }

                    instruction_index++;
                    continue;
                }

                let destination: A64Register = a64_alloc_register(ref values, floating);
                width = a64_scalar_width(ref program, instruction.type_id);
                let loaded: Bool = false;
                if floating {
                    loaded = a64_load_float(ref output, destination, base, offset, width == 64);
                } else {
                    loaded = a64_load_unsigned(ref output, destination, base, offset, width == 64);
                }
                if (base == A64Register.None || destination == A64Register.None || width == 0 || !loaded ||
                    !a64_save_home(ref output, stack.homes, instruction.result, destination, width)) {
                    return a64_lowering_error("cannot encode AArch64 scalar load");
                }
            } else if (instruction.opcode == WirOpcode.Store) {
                if (instruction.operands.length() != 2 || instruction.result != NO_WIR_VALUE) {
                    return a64_lowering_error("store has an invalid WIR shape");
                }

                let slot: A64StackSlot = a64_find_stack_slot(stack.storage, instruction.operands[1]);
                let source_type: WirTypeID = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id;
                let width: Int = a64_integer_width(ref program, source_type);
                let base: A64Register = A64Register.SP;
                let offset: Int = slot.offset;
                if (slot.value == NO_WIR_VALUE) {
                    base = a64_materialize(ref program, instruction.operands[1], stack.homes, ref values, ref output);
                    offset = 0;
                }

                if (width == 128) {
                    let pair: A64RegisterPair = a64_materialize_pair(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                    if (base == A64Register.None || pair.low == A64Register.None || pair.high == A64Register.None ||
                        (slot.value != NO_WIR_VALUE && slot.size != 16) ||
                        !a64_store_unsigned(ref output, pair.low, base, offset, true) ||
                        !a64_store_unsigned(ref output, pair.high, base, offset + 8, true)) {
                        return a64_lowering_error("cannot encode AArch64 128-bit store");
                    }

                    instruction_index++;
                    continue;
                }

                let source: A64Register = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                width = a64_scalar_width(ref program, source_type);
                let stored: Bool = false;
                if (a64_scalar_float(ref program, source_type)) {
                    stored = a64_store_float(ref output, source, base, offset, width == 64);
                } else {
                    stored = a64_store_unsigned(ref output, source, base, offset, width == 64);
                }
                if (source == A64Register.None || base == A64Register.None || width == 0 ||
                    (slot.value != NO_WIR_VALUE && slot.size != width / 8) ||
                    !stored) {
                    return a64_lowering_error("cannot encode AArch64 scalar store");
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
                let destination: A64Register = a64_alloc_register(ref values, false);
                if (address == A64Register.None || destination == A64Register.None ||
                    !a64_atomic_load(
                        ref output,
                        destination,
                        address,
                        width,
                        a64_atomic_acquire(instruction.memory_order)
                    ) ||
                    !a64_save_home(ref output, stack.homes, instruction.result, destination, home_width)) {
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
                let old_value: A64Register = a64_alloc_register(ref values, false);
                let new_value: A64Register = a64_alloc_register(ref values, false);
                let status: A64Register = a64_alloc_register(ref values, false);
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
                    !a64_save_home(ref output, stack.homes, instruction.result, old_value, home_width)) {
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

                let base: A64Register = a64_materialize(ref program, base_id, stack.homes, ref values, ref output);
                let destination: A64Register = a64_alloc_register(ref values, false);
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
                        let temporary: A64Register = a64_alloc_register(ref values, false);
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
                    let scaled: A64Register = a64_alloc_register(ref values, false);
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
                        let stride: A64Register = a64_alloc_register(ref values, false);
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

                if (!a64_save_home(ref output, stack.homes, instruction.result, destination, 64)) {
                    return a64_lowering_error("cannot save an AArch64 aggregate address");
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

                if (target_width == 128) {
                    let source: A64Register = a64_materialize(ref program, source_id, stack.homes, ref values, ref output);
                    let destination: A64RegisterPair = a64_alloc_pair(ref values);
                    let encoded: Bool = source != A64Register.None && destination.low != A64Register.None &&
                                        destination.high != A64Register.None &&
                                        a64_mov_register(ref output, destination.low, source, true) &&
                                        a64_mov_immediate(ref output, destination.high, 0UL, true);
                    if (!encoded || !a64_save_pair(ref output, stack.homes, instruction.result, destination)) {
                        return a64_lowering_error("cannot cast an AArch64 pointer to a 128-bit integer");
                    }
                } else if (source_width == 128) {
                    let source: A64RegisterPair = a64_materialize_pair(ref program, source_id, stack.homes, ref values, ref output);
                    let destination: A64Register = a64_alloc_register(ref values, false);
                    let encoded: Bool = source.low != A64Register.None && destination != A64Register.None &&
                                        a64_mov_register(ref output, destination, source.low, target_width == 64);
                    if (!encoded || !a64_save_home(ref output, stack.homes, instruction.result, destination, target_width)) {
                        return a64_lowering_error("cannot cast a 128-bit integer to an AArch64 pointer");
                    }
                } else {
                    let source: A64Register = a64_materialize(ref program, source_id, stack.homes, ref values, ref output);
                    let destination: A64Register = a64_alloc_register(ref values, false);
                    let encoded: Bool = source != A64Register.None && destination != A64Register.None;
                    if (encoded && instruction.opcode == WirOpcode.IntToPointer && source_width < 64) {
                        let bits: Int = a64_integer_bits(ref program, source_type);
                        encoded = bits > 0 && a64_extend_integer(ref output, destination, source, bits, false, true);
                    } else if encoded {
                        encoded = a64_mov_register(ref output, destination, source, target_width == 64);
                    }
                    if (!encoded || !a64_save_home(ref output, stack.homes, instruction.result, destination, target_width)) {
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
                    let destination: A64RegisterPair = a64_alloc_pair(ref values);
                    let amount: A64Register = a64_alloc_register(ref values, false);
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
                    if (!encoded || !a64_save_pair(ref output, stack.homes, instruction.result, destination)) {
                        return a64_lowering_error("cannot extend an AArch64 integer to 128 bits");
                    }
                } else if (source_bits == 128) {
                    let source: A64RegisterPair = a64_materialize_pair(ref program, source_id, stack.homes, ref values, ref output);
                    let destination: A64Register = a64_alloc_register(ref values, false);
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
                    if (!encoded || !a64_save_home(ref output, stack.homes, instruction.result, destination, target_width)) {
                        return a64_lowering_error("cannot truncate an AArch64 128-bit integer");
                    }
                } else {
                    let source: A64Register = a64_materialize(ref program, source_id, stack.homes, ref values, ref output);
                    let destination: A64Register = a64_alloc_register(ref values, false);
                    let target_width: Int = a64_scalar_width(ref program, instruction.type_id);
                    let extend_bits: Int = source_bits;
                    let signed: Bool = instruction.opcode == WirOpcode.SignExtend;
                    if (instruction.opcode == WirOpcode.Truncate) {
                        extend_bits = target_bits;
                        signed = a64_integer_signed(ref program, instruction.type_id);
                    }
                    if (source == A64Register.None || destination == A64Register.None || target_width == 0 ||
                        !a64_extend_integer(ref output, destination, source, extend_bits, signed, target_width == 64) ||
                        !a64_save_home(ref output, stack.homes, instruction.result, destination, target_width)) {
                        return a64_lowering_error("cannot encode AArch64 integer cast");
                    }
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
                let destination: A64RegisterPair = a64_alloc_pair(ref values);
                if (left.low == A64Register.None || left.high == A64Register.None ||
                    right.low == A64Register.None || right.high == A64Register.None ||
                    destination.low == A64Register.None || destination.high == A64Register.None ||
                    !a64_wide_binary(ref output, instruction.opcode, destination, left, right) ||
                    !a64_save_pair(ref output, stack.homes, instruction.result, destination)) {
                    return a64_lowering_error("cannot encode AArch64 128-bit integer operation");
                }
            } else if (a64_integer_width(ref program, instruction.type_id) == 128 &&
                       instruction.opcode == WirOpcode.Multiply) {
                if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("128-bit multiply has an invalid WIR shape");
                }

                let left: A64RegisterPair = a64_materialize_pair(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let right: A64RegisterPair = a64_materialize_pair(ref program, instruction.operands[1], stack.homes, ref values, ref output);
                let destination: A64RegisterPair = a64_alloc_pair(ref values);
                let temporary: A64Register = a64_alloc_register(ref values, false);
                if (left.low == A64Register.None || left.high == A64Register.None ||
                    right.low == A64Register.None || right.high == A64Register.None ||
                    destination.low == A64Register.None || destination.high == A64Register.None ||
                    temporary == A64Register.None ||
                    !a64_wide_multiply(ref output, destination, left, right, temporary) ||
                    !a64_save_pair(ref output, stack.homes, instruction.result, destination)) {
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
                let destination: A64RegisterPair = a64_alloc_pair(ref values);
                let count: A64Register = a64_alloc_register(ref values, false);
                let work: A64Register = a64_alloc_register(ref values, false);
                let cross: A64Register = a64_alloc_register(ref values, false);
                if (source.low == A64Register.None || source.high == A64Register.None || amount.low == A64Register.None ||
                    destination.low == A64Register.None || destination.high == A64Register.None ||
                    count == A64Register.None || work == A64Register.None || cross == A64Register.None ||
                    !a64_wide_shift(ref output, instruction.opcode, destination, source, amount.low, count, work, cross) ||
                    !a64_save_pair(ref output, stack.homes, instruction.result, destination)) {
                    return a64_lowering_error("cannot encode AArch64 128-bit shift");
                }
            } else if (a64_is_integer_binary(instruction.opcode) && !a64_scalar_float(ref program, instruction.type_id)) {
                if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("integer arithmetic has an invalid WIR shape");
                }

                let left: A64Register = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let right: A64Register = a64_materialize(ref program, instruction.operands[1], stack.homes, ref values, ref output);
                let destination: A64Register = a64_alloc_register(ref values, false);
                let width: Int = a64_scalar_width(ref program, instruction.type_id);
                if (left == A64Register.None || right == A64Register.None || destination == A64Register.None || width == 0) {
                    return a64_lowering_error("AArch64 integer arithmetic ran out of temporary registers");
                }

                let encoded: Bool = a64_emit_integer_binary(ref output, instruction.opcode, destination, left, right, width == 64);
                if (!encoded || !a64_save_home(ref output, stack.homes, instruction.result, destination, width)) {
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
                let result: A64RegisterPair = a64_wide_divide(ref output, signed, remainder);
                if (result.low == A64Register.None || result.high == A64Register.None ||
                    !a64_save_pair(ref output, stack.homes, instruction.result, result)) {
                    return a64_lowering_error("cannot encode AArch64 128-bit division");
                }
            } else if (a64_is_integer_division(instruction.opcode)) {
                if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("integer division has an invalid WIR shape");
                }

                let left: A64Register = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let right: A64Register = a64_materialize(ref program, instruction.operands[1], stack.homes, ref values, ref output);
                let quotient: A64Register = a64_alloc_register(ref values, false);
                let destination: A64Register = quotient;
                let width: Int = a64_scalar_width(ref program, instruction.type_id);
                let signed: Bool = instruction.opcode == WirOpcode.SignedDivide || instruction.opcode == WirOpcode.SignedRemainder;
                let remainder: Bool = instruction.opcode == WirOpcode.SignedRemainder || instruction.opcode == WirOpcode.UnsignedRemainder;
                if remainder { destination = a64_alloc_register(ref values, false); }

                let encoded: Bool = a64_divide_register(ref output, quotient, left, right, signed, width == 64);
                if (encoded && remainder) {
                    encoded = a64_multiply_subtract(ref output, destination, quotient, right, left, width == 64);
                }
                if (left == A64Register.None || right == A64Register.None || quotient == A64Register.None ||
                    destination == A64Register.None || width == 0 || !encoded ||
                    !a64_save_home(ref output, stack.homes, instruction.result, destination, width)) {
                    return a64_lowering_error("cannot encode AArch64 integer division");
                }
            } else if (a64_is_float_binary(instruction.opcode) && a64_scalar_float(ref program, instruction.type_id)) {
                if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("floating-point arithmetic has an invalid WIR shape");
                }

                let left: A64Register = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let right: A64Register = a64_materialize(ref program, instruction.operands[1], stack.homes, ref values, ref output);
                let destination: A64Register = a64_alloc_register(ref values, true);
                let width: Int = a64_scalar_width(ref program, instruction.type_id);
                if (left == A64Register.None || right == A64Register.None || destination == A64Register.None || width == 0 ||
                    !a64_emit_float_binary(ref output, instruction.opcode, destination, left, right, width == 64) ||
                    !a64_save_home(ref output, stack.homes, instruction.result, destination, width)) {
                    return a64_lowering_error("cannot encode AArch64 floating-point arithmetic");
                }
            } else if (instruction.opcode == WirOpcode.FloatNegate) {
                if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("floating-point negate has an invalid WIR shape");
                }

                let source: A64Register = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let destination: A64Register = a64_alloc_register(ref values, true);
                let width: Int = a64_scalar_width(ref program, instruction.type_id);
                if (source == A64Register.None || destination == A64Register.None || width == 0 ||
                    !a64_float_negate(ref output, destination, source, width == 64) ||
                    !a64_save_home(ref output, stack.homes, instruction.result, destination, width)) {
                    return a64_lowering_error("cannot encode AArch64 floating-point negate");
                }
            } else if (a64_is_integer_comparison(instruction.opcode) && instruction.operands.length() == 2 &&
                       a64_integer_width(ref program, program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id) == 128) {
                if (instruction.result == NO_WIR_VALUE || instruction.type_id != program.bool_type) {
                    return a64_lowering_error("128-bit comparison has an invalid WIR shape");
                }

                let left: A64RegisterPair = a64_materialize_pair(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let right: A64RegisterPair = a64_materialize_pair(ref program, instruction.operands[1], stack.homes, ref values, ref output);
                let destination: A64Register = a64_alloc_register(ref values, false);
                let first: A64Register = a64_alloc_register(ref values, false);
                let second: A64Register = a64_alloc_register(ref values, false);
                if (left.low == A64Register.None || left.high == A64Register.None ||
                    right.low == A64Register.None || right.high == A64Register.None ||
                    destination == A64Register.None || first == A64Register.None || second == A64Register.None ||
                    !a64_wide_compare(ref output, instruction.opcode, destination, first, second, left, right) ||
                    !a64_save_home(ref output, stack.homes, instruction.result, destination, 32)) {
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
                let destination: A64Register = a64_alloc_register(ref values, false);
                let width: Int = a64_scalar_width(ref program, left_value.type_id);
                let condition: A64Condition = a64_float_condition(instruction.opcode);
                if (left_value.type_id != right_value.type_id || left == A64Register.None || right == A64Register.None ||
                    destination == A64Register.None || width == 0 || condition == A64Condition.Never ||
                    !a64_float_compare(ref output, left, right, width == 64) ||
                    !a64_set_condition(ref output, destination, condition) ||
                    !a64_save_home(ref output, stack.homes, instruction.result, destination, 32)) {
                    return a64_lowering_error("cannot encode AArch64 floating-point comparison");
                }
            } else if (a64_is_integer_comparison(instruction.opcode)) {
                if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("integer comparison has an invalid WIR shape");
                }

                let left: A64Register = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let right: A64Register = a64_materialize(ref program, instruction.operands[1], stack.homes, ref values, ref output);
                let destination: A64Register = a64_alloc_register(ref values, false);
                let input_type: WirTypeID = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id;
                let width: Int = a64_scalar_width(ref program, input_type);
                let condition: A64Condition = a64_comparison_condition(instruction.opcode);

                if (left == A64Register.None || right == A64Register.None || destination == A64Register.None || width == 0 ||
                    condition == A64Condition.Never || !a64_compare_register(ref output, left, right, width == 64) ||
                    !a64_set_condition(ref output, destination, condition) ||
                    !a64_save_home(ref output, stack.homes, instruction.result, destination, 32)) {
                    return a64_lowering_error("cannot encode AArch64 integer comparison");
                }
            } else if (a64_integer_width(ref program, instruction.type_id) == 128 &&
                       (instruction.opcode == WirOpcode.Negate || instruction.opcode == WirOpcode.Not)) {
                if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("128-bit unary operation has an invalid WIR shape");
                }

                let source: A64RegisterPair = a64_materialize_pair(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let destination: A64RegisterPair = a64_alloc_pair(ref values);
                let temporary: A64Register = a64_alloc_register(ref values, false);
                if (source.low == A64Register.None || source.high == A64Register.None ||
                    destination.low == A64Register.None || destination.high == A64Register.None ||
                    temporary == A64Register.None ||
                    !a64_wide_unary(ref output, instruction.opcode, destination, source, temporary) ||
                    !a64_save_pair(ref output, stack.homes, instruction.result, destination)) {
                    return a64_lowering_error("cannot encode AArch64 128-bit unary operation");
                }
            } else if (instruction.opcode == WirOpcode.Negate || instruction.opcode == WirOpcode.Not ||
                       instruction.opcode == WirOpcode.Abs) {
                if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("integer unary operation has an invalid WIR shape");
                }

                let source: A64Register = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let destination: A64Register = a64_alloc_register(ref values, false);
                let width: Int = a64_scalar_width(ref program, instruction.type_id);
                let encoded: Bool = false;
                if (instruction.opcode == WirOpcode.Negate) {
                    encoded = a64_sub_register(ref output, destination, A64Register.ZR, source, width == 64);
                } else if (instruction.opcode == WirOpcode.Not && instruction.type_id == program.bool_type) {
                    let one: A64Register = a64_alloc_register(ref values, false);
                    encoded = one != A64Register.None &&
                              a64_mov_immediate(ref output, one, 1UL, false) &&
                              a64_logical_register(ref output, destination, source, one, 2, false);
                } else if (instruction.opcode == WirOpcode.Not) {
                    encoded = a64_invert_register(ref output, destination, source, width == 64);
                } else {
                    let negative: A64Register = a64_alloc_register(ref values, false);
                    encoded = negative != A64Register.None &&
                              a64_compare_zero(ref output, source, width == 64) &&
                              a64_sub_register(ref output, negative, A64Register.ZR, source, width == 64) &&
                              a64_select_condition(ref output, destination, negative, source, A64Condition.Minus, width == 64);
                }
                if (source == A64Register.None || destination == A64Register.None || width == 0 || !encoded ||
                    !a64_save_home(ref output, stack.homes, instruction.result, destination, width)) {
                    return a64_lowering_error("cannot encode AArch64 integer unary operation");
                }
            } else if (instruction.opcode == WirOpcode.NullCheck) {
                if (instruction.operands.length() != 1 || instruction.result != NO_WIR_VALUE) {
                    return a64_lowering_error("AArch64 null check has an invalid WIR shape");
                }

                let checked_id: WirValueID = instruction.operands[0];
                let checked_type: WirTypeID = program.arena.values[wir_id_index(UInt32(checked_id))].type_id;
                let type: WirType = program.arena.types[wir_id_index(UInt32(checked_type))];
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
            } else if (instruction.opcode == WirOpcode.Call) {
                if (instruction.operands.length() == 0 || instruction.operands.length() > 17 || instruction.call_type == NO_WIR_TYPE) {
                    return a64_lowering_error("initial AArch64 calls support a direct target and register-passed scalar arguments");
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

                let integer_index: Int = 0;
                let float_index: Int = 0;
                let argument_index: Int = 1;
                while (argument_index < instruction.operands.length()) {
                    let argument: WirValueID = instruction.operands[argument_index];
                    let argument_type: WirTypeID = program.arena.values[wir_id_index(UInt32(argument))].type_id;
                    let width: Int = a64_integer_width(ref program, argument_type);
                    let floating: Bool = a64_scalar_float(ref program, argument_type);

                    if (width == 128) {
                        let pair_index: Int = a64_pair_argument_index(integer_index);
                        let pair: A64RegisterPair = a64_materialize_pair(ref program, argument, stack.homes, ref values, ref output);
                        let low: A64Register = a64_argument_register(pair_index, false);
                        let high: A64Register = a64_argument_register(pair_index + 1, false);
                        if (pair_index < 0 || pair.low == A64Register.None || pair.high == A64Register.None ||
                            !a64_mov_register(ref output, low, pair.low, true) ||
                            !a64_mov_register(ref output, high, pair.high, true)) {
                            return a64_lowering_error("cannot assign an AArch64 128-bit call argument");
                        }

                        integer_index = pair_index + 2;
                        argument_index++;
                        continue;
                    }

                    width = a64_scalar_width(ref program, argument_type);
                    let source: A64Register = a64_materialize(ref program, argument, stack.homes, ref values, ref output);
                    let position: Int = integer_index;
                    if floating { position = float_index; }
                    let destination: A64Register = a64_argument_register(position, floating);
                    let moved: Bool = source == destination;
                    if (!moved && floating) {
                        moved = a64_float_move(ref output, destination, source, width == 64);
                    } else if (!moved) {
                        moved = a64_mov_register(ref output, destination, source, width == 64);
                    }
                    if (width == 0 || source == A64Register.None || destination == A64Register.None || !moved) {
                        return a64_lowering_error("cannot assign an AArch64 call argument");
                    }
                    if floating { float_index++; } else { integer_index++; }
                    argument_index++;
                }

                if (!a64_branch_symbol(ref output, callee_function.name, true)) {
                    return a64_lowering_error("cannot encode an AArch64 direct call");
                }

                let result_width: Int = a64_integer_width(ref program, instruction.type_id);
                if (instruction.result != NO_WIR_VALUE && result_width == 128) {
                    if (!a64_save_pair(
                        ref output,
                        stack.homes,
                        instruction.result,
                        A64RegisterPair(low=A64Register.X0, high=A64Register.X1)
                    )) {
                        return a64_lowering_error("cannot bind the AArch64 128-bit call result");
                    }

                    instruction_index++;
                    continue;
                }

                result_width = a64_scalar_width(ref program, instruction.type_id);
                let result_register: A64Register = A64Register.X0;
                if (a64_scalar_float(ref program, instruction.type_id)) { result_register = A64Register.V0; }
                if (instruction.result != NO_WIR_VALUE &&
                    (result_width == 0 || !a64_save_home(ref output, stack.homes, instruction.result, result_register, result_width))) {
                    return a64_lowering_error("cannot bind the AArch64 call result");
                }
            } else if (instruction.opcode == WirOpcode.Trap || instruction.opcode == WirOpcode.Unreachable) {
                if (instruction.operands.length() != 0 || instruction.result != NO_WIR_VALUE) {
                    return a64_lowering_error("AArch64 trap instruction has an invalid WIR shape");
                }

                a64_trap(ref output);
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
                    let value_type: WirTypeID = program.arena.values[wir_id_index(UInt32(value))].type_id;
                    if (a64_integer_width(ref program, value_type) == 128) {
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

    let data: MachineDataResult = machine_emit_globals(ref program, wir_type_layouts(program), ".data.rel.ro", true);
    if (data.message.length() != 0) { return a64_module_error(data.message); }

    i = 0;
    while (i < data.symbols.length()) {
        let symbol: MachineSymbol = data.symbols[i];
        symbols.append(A64Symbol(name=symbol.name, section=symbol.section, offset=symbol.offset, external=symbol.external));
        i++;
    }
    i = 0;
    while (i < data.relocations.length()) {
        let relocation: MachineDataRelocation = data.relocations[i];
        relocations.append(A64Relocation(section=relocation.section, offset=relocation.offset, kind=A64RelocationKind.Abs64, symbol=relocation.symbol, addend=relocation.addend));
        i++;
    }

    if (symbols.length() == 0) {
        return a64_module_error("the AArch64 module contains no defined functions");
    }

    let sections: Vector(A64Section) = [A64Section(name=".text", bytes=text, alignment=4, executable=true, writable=false)];
    i = 0;
    while (i < data.sections.length()) {
        let section: MachineSection = data.sections[i];
        sections.append(A64Section(name=section.name, bytes=section.bytes, alignment=section.alignment, executable=section.executable, writable=section.writable));
        i++;
    }

    return A64ModuleResult(
        errors=[],
        sections=sections,
        symbols=symbols,
        relocations=relocations
    );
}
