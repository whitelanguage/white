// src/compiler/machine/aarch64/types.wl
import * from "model.wl"
import * from "../../wir/model.wl"


func a64_scalar_width(ref program: WirModule, type_id: WirTypeID) -> Int {
    let index: Int = wir_id_index(UInt32(type_id));
    if (index < 0 || index >= program.arena.types.length()) { return 0; }

    let ptr type: WirType = ref program.arena.types[index];
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

    let ptr type: WirType = ref program.arena.types[index];
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

    let ptr type: WirType = ref program.arena.types[index];
    if (type.kind == WirTypeKind.BoolType) {
        return 1;
    }
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

func a64_stack_value_size(ref program: WirModule, type_id: WirTypeID, layouts: Vector(WirTypeLayout)) -> Int {
    let scalar: Int = a64_value_size(ref program, type_id);
    if (scalar != 0) {
        return scalar;
    }

    let index: Int = wir_id_index(UInt32(type_id));
    if (index < 0 || index >= layouts.length() || !layouts[index].valid ||
        layouts[index].size > 2147483647UL) {
        return 0;
    }

    return a64_align(Int(layouts[index].size), 8);
}

func a64_stack_value_alignment(type_id: WirTypeID, layouts: Vector(WirTypeLayout), fallback: Int) -> Int {
    let index: Int = wir_id_index(UInt32(type_id));
    if (index >= 0 && index < layouts.length() && layouts[index].valid &&
        layouts[index].size == UInt64(fallback)) {
        return layouts[index].alignment;
    }

    return fallback;
}

func a64_aggregate_type(ref program: WirModule, type_id: WirTypeID) -> Bool {
    let index: Int = wir_id_index(UInt32(type_id));
    if (index < 0 || index >= program.arena.types.length()) {
        return false;
    }

    let kind: WirTypeKind = program.arena.types[index].kind;
    return kind == WirTypeKind.Struct || kind == WirTypeKind.Array;
}

func a64_align(value: Int, alignment: Int) -> Int {
    if (alignment <= 1) { return value; }
    return ((value + alignment - 1) / alignment) * alignment;
}

func a64_memory_width(ref program: WirModule, type_id: WirTypeID) -> Int {
    let index: Int = wir_id_index(UInt32(type_id));
    if (index < 0 || index >= program.arena.types.length()) {
        return 0;
    }

    let ptr type: WirType = ref program.arena.types[index];
    if (type.kind == WirTypeKind.BoolType) { return 8; }
    if (type.kind == WirTypeKind.Pointer || type.kind == WirTypeKind.Function) { return 64; }
    if (type.kind == WirTypeKind.FloatType) { return type.bits; }
    if (type.kind != WirTypeKind.SignedInt && type.kind != WirTypeKind.UnsignedInt) { return 0; }
    if (type.bits <= 8) { return 8; }
    if (type.bits <= 16) { return 16; }
    if (type.bits <= 32) { return 32; }
    if (type.bits <= 64) { return 64; }
    if (type.bits == 128) { return 128; }

    return 0;
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

func a64_instruction_uses_wide_int(ref program: WirModule, instruction: WirInstruction) -> Bool {
    if (instruction.type_id != NO_WIR_TYPE && a64_integer_width(ref program, instruction.type_id) == 128) {
        return true;
    }

    let i: Int = 0;
    while (i < instruction.operands.length()) {
        let index: Int = wir_id_index(UInt32(instruction.operands[i]));
        if (index >= 0 && index < program.arena.values.length() &&
            a64_integer_width(ref program, program.arena.values[index].type_id) == 128) {
            return true;
        }
        i++;
    }

    return false;
}
