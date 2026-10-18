// src/compiler/machine/aarch64/fp.wl
import * from "model.wl"
import A64CodeBuffer, a64_emit_u32 from "encoder.wl"
import WirModule, WirTypeID, WirTypeKind, WirOpcode, wir_id_index from "../../wir/model.wl"


func a64_load_float(ref output: A64CodeBuffer, destination: A64Register, base: A64Register, offset: Int, double: Bool) -> Bool {
// LDR S/D uses the same scaled unsigned offset as the integer load.
    let rt: Int = a64_vec_code(destination);
    let rn: Int = a64_gpr_code(base);
    let scale: Int = 4;
    if double { scale = 8; }

    if (rt < 0 || rn < 0 || offset < 0 || offset % scale != 0 || offset / scale > 4095) {
        return false;
    }

    let word: UInt32 = 0xBD400000U;
    if double { word = 0xFD400000U; }
    word |= UInt32((offset / scale) << 10);
    word |= UInt32(rn << 5);
    word |= UInt32(rt);
    a64_emit_u32(ref output, word);

    return true;
}

func a64_store_float(ref output: A64CodeBuffer, source: A64Register, base: A64Register, offset: Int, double: Bool) -> Bool {
    let rt: Int = a64_vec_code(source);
    let rn: Int = a64_gpr_code(base);
    let scale: Int = 4;
    if double { scale = 8; }

    if (rt < 0 || rn < 0 || offset < 0 || offset % scale != 0 || offset / scale > 4095) {
        return false;
    }

    let word: UInt32 = 0xBD000000U;
    if double { word = 0xFD000000U; }
    word |= UInt32((offset / scale) << 10);
    word |= UInt32(rn << 5);
    word |= UInt32(rt);
    a64_emit_u32(ref output, word);

    return true;
}

func a64_float_from_bits(ref output: A64CodeBuffer, destination: A64Register, source: A64Register, double: Bool) -> Bool {
// FMOV transfers the bit pattern, it does not perform a numeric conversion.
    let rd: Int = a64_vec_code(destination);
    let rn: Int = a64_gpr_code(source);
    if (rd < 0 || rn < 0 || source == A64Register.SP) { return false; }

    let word: UInt32 = 0x1E270000U;
    if double { word = 0x9E670000U; }
    word |= UInt32(rn << 5);
    word |= UInt32(rd);
    a64_emit_u32(ref output, word);

    return true;
}

func a64_float_to_bits(ref output: A64CodeBuffer, destination: A64Register, source: A64Register, double: Bool) -> Bool {
// this is the opposite FMOV form, from the SIMD bank back to a general register
    let rd: Int = a64_gpr_code(destination);
    let rn: Int = a64_vec_code(source);
    if (rd < 0 || rn < 0 || destination == A64Register.SP) {
        return false;
    }

    let word: UInt32 = 0x1E260000U;
    if double { word = 0x9E660000U; }
    word |= UInt32(rn << 5);
    word |= UInt32(rd);
    a64_emit_u32(ref output, word);

    return true;
}

func a64_float_binary(ref output: A64CodeBuffer, destination: A64Register, left: A64Register, right: A64Register, operation: Int, double: Bool) -> Bool {
// operation is add, sub, mul, div in that order.
    let rd: Int = a64_vec_code(destination);
    let rn: Int = a64_vec_code(left);
    let rm: Int = a64_vec_code(right);
    if (rd < 0 || rn < 0 || rm < 0 || operation < 0 || operation > 3) {
        return false;
    }

    let word: UInt32 = 0x1E202800U;
    if (operation == 1) { word = 0x1E203800U; }
    if (operation == 2) { word = 0x1E200800U; }
    if (operation == 3) { word = 0x1E201800U; }
    if double { word |= 0x00400000U; }
    word |= UInt32(rm << 16);
    word |= UInt32(rn << 5);
    word |= UInt32(rd);
    a64_emit_u32(ref output, word);

    return true;
}

func a64_float_negate(ref output: A64CodeBuffer, destination: A64Register, source: A64Register, double: Bool) -> Bool {
    let rd: Int = a64_vec_code(destination);
    let rn: Int = a64_vec_code(source);
    if (rd < 0 || rn < 0) { return false; }

    let word: UInt32 = 0x1E214000U;
    if double { word = 0x1E614000U; }
    word |= UInt32(rn << 5);
    word |= UInt32(rd);
    a64_emit_u32(ref output, word);

    return true;
}

func a64_float_move(ref output: A64CodeBuffer, destination: A64Register, source: A64Register, double: Bool) -> Bool {
    let rd: Int = a64_vec_code(destination);
    let rn: Int = a64_vec_code(source);
    if (rd < 0 || rn < 0) { return false; }

    let word: UInt32 = 0x1E204000U;
    if double { word = 0x1E604000U; }
    word |= UInt32(rn << 5);
    word |= UInt32(rd);
    a64_emit_u32(ref output, word);

    return true;
}

func a64_int_to_float(ref output: A64CodeBuffer, destination: A64Register, source: A64Register, signed: Bool, source_wide: Bool, result_double: Bool) -> Bool {
    let rd: Int = a64_vec_code(destination);
    let rn: Int = a64_gpr_code(source);
    if (rd < 0 || rn < 0 || source == A64Register.SP) {
        return false;
    }

    let word: UInt32 = 0x1E230000U;
    if signed { word = 0x1E220000U; }
    if source_wide { word |= 0x80000000U; }
    if result_double { word |= 0x00400000U; }
    word |= UInt32(rn << 5);
    word |= UInt32(rd);
    a64_emit_u32(ref output, word);

    return true;
}

func a64_float_to_int(ref output: A64CodeBuffer, destination: A64Register, source: A64Register, signed: Bool, source_double: Bool, result_wide: Bool) -> Bool {
    let rd: Int = a64_gpr_code(destination);
    let rn: Int = a64_vec_code(source);
    if (rd < 0 || rn < 0 || destination == A64Register.SP) {
        return false;
    }

    let word: UInt32 = 0x1E390000U;
    if signed { word = 0x1E380000U; }
    if source_double { word |= 0x00400000U; }
    if result_wide { word |= 0x80000000U; }
    word |= UInt32(rn << 5);
    word |= UInt32(rd);
    a64_emit_u32(ref output, word);

    return true;
}

func a64_convert_float(ref output: A64CodeBuffer, destination: A64Register, source: A64Register, extend: Bool) -> Bool {
    let rd: Int = a64_vec_code(destination);
    let rn: Int = a64_vec_code(source);
    if (rd < 0 || rn < 0) {
        return false;
    }

    let word: UInt32 = 0x1E624000U;
    if extend { word = 0x1E22C000U; }
    word |= UInt32(rn << 5);
    word |= UInt32(rd);
    a64_emit_u32(ref output, word);

    return true;
}

func a64_float_compare(ref output: A64CodeBuffer, left: A64Register, right: A64Register, double: Bool) -> Bool {
    let rn: Int = a64_vec_code(left);
    let rm: Int = a64_vec_code(right);
    if (rn < 0 || rm < 0) { return false; }

    let word: UInt32 = 0x1E202000U;
    if double { word = 0x1E602000U; }
    word |= UInt32(rm << 16);
    word |= UInt32(rn << 5);
    a64_emit_u32(ref output, word);

    return true;
}

func a64_scalar_float(ref program: WirModule, type_id: WirTypeID) -> Bool {
    let index: Int = wir_id_index(UInt32(type_id));
    return index >= 0 && index < program.arena.types.length() && program.arena.types[index].kind == WirTypeKind.FloatType;
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
