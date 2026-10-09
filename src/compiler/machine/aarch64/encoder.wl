// src/compiler/machine/aarch64/encoder.wl
import * from "model.wl"


struct A64CodeBuffer(bytes: Vector(Byte), relocations: Vector(A64Relocation))

func a64_new_code_buffer() -> A64CodeBuffer {
    return A64CodeBuffer(bytes=[], relocations=[]);
}

func a64_emit_u32(ref output: A64CodeBuffer, value: UInt32) -> Void {
// AArch64 Linux uses little-endian instruction words.
    output.bytes.append(Byte(value & 255U));
    output.bytes.append(Byte((value >> 8U) & 255U));
    output.bytes.append(Byte((value >> 16U) & 255U));
    output.bytes.append(Byte((value >> 24U) & 255U));
}

func a64_patch_u32(ref output: A64CodeBuffer, offset: Int, value: UInt32) -> Bool {
    if (offset < 0 || offset + 4 > output.bytes.length() || offset % 4 != 0) {
        return false;
    }

    output.bytes[offset] = Byte(value & 255U);
    output.bytes[offset + 1] = Byte((value >> 8U) & 255U);
    output.bytes[offset + 2] = Byte((value >> 16U) & 255U);
    output.bytes[offset + 3] = Byte((value >> 24U) & 255U);

    return true;
}

func a64_add_immediate(ref output: A64CodeBuffer, destination: A64Register, source: A64Register, immediate: Int, wide: Bool) -> Bool {
    let rd: Int = a64_gpr_code(destination);
    let rn: Int = a64_gpr_code(source);

    if (rd < 0 || rn < 0 || immediate < 0 || immediate > 4095 || destination == A64Register.ZR || source == A64Register.ZR) {
        return false;
    }

    let word: UInt32 = 0x11000000U;
    if wide { word = 0x91000000U; }
    word |= UInt32(immediate << 10);
    word |= UInt32(rn << 5);
    word |= UInt32(rd);
    a64_emit_u32(ref output, word);

    return true;
}

func a64_sub_immediate(ref output: A64CodeBuffer, destination: A64Register, source: A64Register, immediate: Int, wide: Bool) -> Bool {
    let rd: Int = a64_gpr_code(destination);
    let rn: Int = a64_gpr_code(source);

    if (rd < 0 || rn < 0 || immediate < 0 || immediate > 4095 || destination == A64Register.ZR || source == A64Register.ZR) {
        return false;
    }

    let word: UInt32 = 0x51000000U;
    if wide { word = 0xD1000000U; }
    word |= UInt32(immediate << 10);
    word |= UInt32(rn << 5);
    word |= UInt32(rd);
    a64_emit_u32(ref output, word);

    return true;
}

func a64_add_register(ref output: A64CodeBuffer, destination: A64Register, left: A64Register, right: A64Register, wide: Bool) -> Bool {
    let rd: Int = a64_gpr_code(destination);
    let rn: Int = a64_gpr_code(left);
    let rm: Int = a64_gpr_code(right);

    if (rd < 0 || rn < 0 || rm < 0 || destination == A64Register.SP || left == A64Register.SP || right == A64Register.SP) {
        return false;
    }

    let word: UInt32 = 0x0B000000U;
    if wide { word = 0x8B000000U; }
    word |= UInt32(rm << 16);
    word |= UInt32(rn << 5);
    word |= UInt32(rd);
    a64_emit_u32(ref output, word);

    return true;
}

func a64_sub_register(ref output: A64CodeBuffer, destination: A64Register, left: A64Register, right: A64Register, wide: Bool) -> Bool {
    let rd: Int = a64_gpr_code(destination);
    let rn: Int = a64_gpr_code(left);
    let rm: Int = a64_gpr_code(right);

    if (rd < 0 || rn < 0 || rm < 0 || destination == A64Register.SP || left == A64Register.SP || right == A64Register.SP) {
        return false;
    }

    let word: UInt32 = 0x4B000000U;
    if wide { word = 0xCB000000U; }
    word |= UInt32(rm << 16);
    word |= UInt32(rn << 5);
    word |= UInt32(rd);
    a64_emit_u32(ref output, word);

    return true;
}

func a64_multiply_register(ref output: A64CodeBuffer, destination: A64Register, left: A64Register, right: A64Register, wide: Bool) -> Bool {
// MUL is MADD with XZR/WZR as the addend.
    let rd: Int = a64_gpr_code(destination);
    let rn: Int = a64_gpr_code(left);
    let rm: Int = a64_gpr_code(right);

    if (rd < 0 || rn < 0 || rm < 0 || destination == A64Register.SP || left == A64Register.SP || right == A64Register.SP) {
        return false;
    }

    let word: UInt32 = 0x1B007C00U;
    if wide { word = 0x9B007C00U; }
    word |= UInt32(rm << 16);
    word |= UInt32(rn << 5);
    word |= UInt32(rd);
    a64_emit_u32(ref output, word);

    return true;
}

func a64_divide_register(ref output: A64CodeBuffer, destination: A64Register, left: A64Register, right: A64Register, signed: Bool, wide: Bool) -> Bool {
    let rd: Int = a64_gpr_code(destination);
    let rn: Int = a64_gpr_code(left);
    let rm: Int = a64_gpr_code(right);
    if (rd < 0 || rn < 0 || rm < 0 || destination == A64Register.SP || left == A64Register.SP || right == A64Register.SP) {
        return false;
    }

    let word: UInt32 = 0x1AC00800U;
    if signed { word = 0x1AC00C00U; }
    if wide { word |= 0x80000000U; }
    word |= UInt32(rm << 16);
    word |= UInt32(rn << 5);
    word |= UInt32(rd);
    a64_emit_u32(ref output, word);

    return true;
}

func a64_multiply_subtract(ref output: A64CodeBuffer, destination: A64Register, left: A64Register, right: A64Register, addend: A64Register, wide: Bool) -> Bool {
// MSUB computes addend - left * right, division uses it for the remainder.
    let rd: Int = a64_gpr_code(destination);
    let rn: Int = a64_gpr_code(left);
    let rm: Int = a64_gpr_code(right);
    let ra: Int = a64_gpr_code(addend);
    if (rd < 0 || rn < 0 || rm < 0 || ra < 0 || destination == A64Register.SP ||
        left == A64Register.SP || right == A64Register.SP || addend == A64Register.SP) {
        return false;
    }

    let word: UInt32 = 0x1B008000U;
    if wide { word = 0x9B008000U; }
    word |= UInt32(rm << 16);
    word |= UInt32(ra << 10);
    word |= UInt32(rn << 5);
    word |= UInt32(rd);
    a64_emit_u32(ref output, word);

    return true;
}

func a64_logical_register(ref output: A64CodeBuffer, destination: A64Register, left: A64Register, right: A64Register, operation: Int, wide: Bool) -> Bool {
    let rd: Int = a64_gpr_code(destination);
    let rn: Int = a64_gpr_code(left);
    let rm: Int = a64_gpr_code(right);
    if (rd < 0 || rn < 0 || rm < 0 || operation < 0 || operation > 2 ||
        destination == A64Register.SP || left == A64Register.SP || right == A64Register.SP) {
        return false;
    }

    let word: UInt32 = 0x0A000000U;
    if (operation == 1) { word = 0x2A000000U; }
    if (operation == 2) { word = 0x4A000000U; }
    if wide { word |= 0x80000000U; }
    word |= UInt32(rm << 16);
    word |= UInt32(rn << 5);
    word |= UInt32(rd);
    a64_emit_u32(ref output, word);

    return true;
}

func a64_invert_register(ref output: A64CodeBuffer, destination: A64Register, source: A64Register, wide: Bool) -> Bool {
// MVN is ORN with the zero register as the first operand.
    let rd: Int = a64_gpr_code(destination);
    let rm: Int = a64_gpr_code(source);
    if (rd < 0 || rm < 0 || destination == A64Register.SP || source == A64Register.SP) {
        return false;
    }

    let word: UInt32 = 0x2A2003E0U;
    if wide { word = 0xAA2003E0U; }
    word |= UInt32(rm << 16);
    word |= UInt32(rd);
    a64_emit_u32(ref output, word);

    return true;
}

func a64_shift_register(ref output: A64CodeBuffer, destination: A64Register, value: A64Register, amount: A64Register, operation: Int, wide: Bool) -> Bool {
    let rd: Int = a64_gpr_code(destination);
    let rn: Int = a64_gpr_code(value);
    let rm: Int = a64_gpr_code(amount);
    if (rd < 0 || rn < 0 || rm < 0 || operation < 0 || operation > 2 ||
        destination == A64Register.SP || value == A64Register.SP || amount == A64Register.SP) {
        return false;
    }

    let word: UInt32 = 0x1AC02000U;
    if (operation == 1) { word = 0x1AC02800U; }
    if (operation == 2) { word = 0x1AC02400U; }
    if wide { word |= 0x80000000U; }
    word |= UInt32(rm << 16);
    word |= UInt32(rn << 5);
    word |= UInt32(rd);
    a64_emit_u32(ref output, word);

    return true;
}

func a64_mov_register(ref output: A64CodeBuffer, destination: A64Register, source: A64Register, wide: Bool) -> Bool {
    let rd: Int = a64_gpr_code(destination);
    let rm: Int = a64_gpr_code(source);

    if (rd < 0 || rm < 0 || destination == A64Register.SP || source == A64Register.SP) {
        return false;
    }

    let word: UInt32 = 0x2A0003E0U;
    if wide { word = 0xAA0003E0U; }
    word |= UInt32(rm << 16);
    word |= UInt32(rd);
    a64_emit_u32(ref output, word);

    return true;
}

func a64_compare_register(ref output: A64CodeBuffer, left: A64Register, right: A64Register, wide: Bool) -> Bool {
// CMP is SUBS with the zero register as its discarded destination.
    let rn: Int = a64_gpr_code(left);
    let rm: Int = a64_gpr_code(right);

    if (rn < 0 || rm < 0 || left == A64Register.SP || right == A64Register.SP) {
        return false;
    }

    let word: UInt32 = 0x6B00001FU;
    if wide { word = 0xEB00001FU; }
    word |= UInt32(rm << 16);
    word |= UInt32(rn << 5);
    a64_emit_u32(ref output, word);

    return true;
}

func a64_compare_zero(ref output: A64CodeBuffer, value: A64Register, wide: Bool) -> Bool {
    let rn: Int = a64_gpr_code(value);
    if (rn < 0 || value == A64Register.SP) { return false; }

    let word: UInt32 = 0x7100001FU;
    if wide { word = 0xF100001FU; }
    word |= UInt32(rn << 5);
    a64_emit_u32(ref output, word);

    return true;
}

func a64_load_unsigned(ref output: A64CodeBuffer, destination: A64Register, base: A64Register, offset: Int, wide: Bool) -> Bool {
// scalar stack traffic uses the unsigned scaled LDR form.
    let rt: Int = a64_gpr_code(destination);
    let rn: Int = a64_gpr_code(base);
    let scale: Int = 4;
    if wide { scale = 8; }

    if (rt < 0 || rn < 0 || destination == A64Register.SP || offset < 0 || offset % scale != 0 || offset / scale > 4095) {
        return false;
    }

    let word: UInt32 = 0xB9400000U;
    if wide { word = 0xF9400000U; }
    word |= UInt32((offset / scale) << 10);
    word |= UInt32(rn << 5);
    word |= UInt32(rt);
    a64_emit_u32(ref output, word);

    return true;
}

func a64_store_unsigned(ref output: A64CodeBuffer, source: A64Register, base: A64Register, offset: Int, wide: Bool) -> Bool {
// STR shares LDR's scaled immediate layout.
    let rt: Int = a64_gpr_code(source);
    let rn: Int = a64_gpr_code(base);
    let scale: Int = 4;
    if wide { scale = 8; }

    if (rt < 0 || rn < 0 || source == A64Register.SP || offset < 0 || offset % scale != 0 || offset / scale > 4095) {
        return false;
    }

    let word: UInt32 = 0xB9000000U;
    if wide { word = 0xF9000000U; }
    word |= UInt32((offset / scale) << 10);
    word |= UInt32(rn << 5);
    word |= UInt32(rt);
    a64_emit_u32(ref output, word);

    return true;
}

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

func a64_condition_code(condition: A64Condition) -> Int {
    if (condition == A64Condition.Equal) { return 0; }
    if (condition == A64Condition.NotEqual) { return 1; }
    if (condition == A64Condition.CarrySet) { return 2; }
    if (condition == A64Condition.CarryClear) { return 3; }
    if (condition == A64Condition.Minus) { return 4; }
    if (condition == A64Condition.Plus) { return 5; }
    if (condition == A64Condition.Overflow) { return 6; }
    if (condition == A64Condition.NoOverflow) { return 7; }
    if (condition == A64Condition.UnsignedHigher) { return 8; }
    if (condition == A64Condition.UnsignedLowerOrSame) { return 9; }
    if (condition == A64Condition.SignedGreaterOrEqual) { return 10; }
    if (condition == A64Condition.SignedLess) { return 11; }
    if (condition == A64Condition.SignedGreater) { return 12; }
    if (condition == A64Condition.SignedLessOrEqual) { return 13; }
    if (condition == A64Condition.Always) { return 14; }
    if (condition == A64Condition.Never) { return 15; }

    return -1;
}

func a64_set_condition(ref output: A64CodeBuffer, destination: A64Register, condition: A64Condition) -> Bool {
// CSET is CSINC Wd, WZR, WZR with the requested condition inverted.
    let rd: Int = a64_gpr_code(destination);
    let code: Int = a64_condition_code(condition);

    if (rd < 0 || destination == A64Register.SP || code < 0 || code >= 14) {
        return false;
    }

    let word: UInt32 = 0x1A9F07E0U;
    word |= UInt32((code ^ 1) << 12);
    word |= UInt32(rd);
    a64_emit_u32(ref output, word);

    return true;
}

func a64_select_condition(ref output: A64CodeBuffer, destination: A64Register, when_true: A64Register, when_false: A64Register, condition: A64Condition, wide: Bool) -> Bool {
    let rd: Int = a64_gpr_code(destination);
    let rn: Int = a64_gpr_code(when_true);
    let rm: Int = a64_gpr_code(when_false);
    let code: Int = a64_condition_code(condition);
    if (rd < 0 || rn < 0 || rm < 0 || code < 0 || code >= 14 ||
        destination == A64Register.SP || when_true == A64Register.SP || when_false == A64Register.SP) {
        return false;
    }

    let word: UInt32 = 0x1A800000U;
    if wide { word = 0x9A800000U; }
    word |= UInt32(rm << 16);
    word |= UInt32(code << 12);
    word |= UInt32(rn << 5);
    word |= UInt32(rd);
    a64_emit_u32(ref output, word);

    return true;
}

func a64_mov_wide(ref output: A64CodeBuffer, destination: A64Register, immediate: UInt32, shift: Int, keep: Bool, wide: Bool) -> Bool {
    let rd: Int = a64_gpr_code(destination);
    let max_shift: Int = 16;

    if wide { max_shift = 48; }
    if (rd < 0 || destination == A64Register.SP || immediate > 65535U || shift < 0 || shift > max_shift || shift % 16 != 0) {
        return false;
    }

    let word: UInt32 = 0x52800000U;
    if keep { word = 0x72800000U; }
    if wide {
        word = 0xD2800000U;
        if keep { word = 0xF2800000U; }
    }
    word |= UInt32((shift / 16) << 21);
    word |= immediate << 5U;
    word |= UInt32(rd);
    a64_emit_u32(ref output, word);

    return true;
}

func a64_mov_immediate(ref output: A64CodeBuffer, destination: A64Register, value: UInt64, wide: Bool) -> Bool {
// MOVZ creates the value and MOVK fills only the non-zero upper halfwords.
// This is deliberately simple, the instruction selector can consider MOVN later.
    let pieces: Int = 2;
    if wide { pieces = 4; }

    let first: UInt32 = UInt32(value & 65535UL);
    if (!a64_mov_wide(ref output, destination, first, 0, false, wide)) {
        return false;
    }

    let i: Int = 1;
    while (i < pieces) {
        let half: UInt32 = UInt32((value >> UInt64(i * 16)) & 65535UL);
        if (half != 0U && !a64_mov_wide(ref output, destination, half, i * 16, true, wide)) {
            return false;
        }
        i++;
    }

    return true;
}

func a64_return(ref output: A64CodeBuffer, register: A64Register) -> Bool {
    let rn: Int = a64_gpr_code(register);

    if (rn < 0 || register == A64Register.SP) { return false; }
    a64_emit_u32(ref output, 0xD65F0000U | UInt32(rn << 5));

    return true;
}

func a64_branch_register(ref output: A64CodeBuffer, register: A64Register, link: Bool) -> Bool {
    let rn: Int = a64_gpr_code(register);

    if (rn < 0 || register == A64Register.SP) { return false; }
    let word: UInt32 = 0xD61F0000U;
    if link { word = 0xD63F0000U; }
    a64_emit_u32(ref output, word | UInt32(rn << 5));

    return true;
}

func a64_branch(ref output: A64CodeBuffer, displacement: Int, link: Bool) -> Bool {
// B and BL store a signed 26-bit displacement in instruction words.
    if (displacement % 4 != 0 || displacement < -134217728 || displacement > 134217724) {
        return false;
    }

    let immediate: Long = Long(displacement / 4);
    if (immediate < 0L) { immediate += 67108864L; }
    let word: UInt32 = 0x14000000U;
    if link { word = 0x94000000U; }
    word |= UInt32(immediate) & 0x03FFFFFFU;
    a64_emit_u32(ref output, word);

    return true;
}

func a64_conditional_branch(ref output: A64CodeBuffer, displacement: Int, condition: A64Condition) -> Bool {
// B.cond has a signed 19-bit word displacement, just under one MiB each way.
    let code: Int = a64_condition_code(condition);
    if (code < 0 || displacement % 4 != 0 || displacement < -1048576 || displacement > 1048572) {
        return false;
    }

    let immediate: Long = Long(displacement / 4);
    if (immediate < 0L) { immediate += 524288L; }

    let word: UInt32 = 0x54000000U;
    word |= (UInt32(immediate) & 0x0007FFFFU) << 5U;
    word |= UInt32(code);
    a64_emit_u32(ref output, word);

    return true;
}

func a64_patch_branch(ref output: A64CodeBuffer, offset: Int, target: Int, condition: A64Condition, conditional: Bool) -> Bool {
    if (offset < 0 || offset + 4 > output.bytes.length()) { return false; }

    let patched: A64CodeBuffer = a64_new_code_buffer();
    let ok: Bool = false;
    if conditional {
        ok = a64_conditional_branch(ref patched, target - offset, condition);
    } else {
        ok = a64_branch(ref patched, target - offset, false);
    }
    if (!ok || patched.bytes.length() != 4) { return false; }

    let word: UInt32 = UInt32(patched.bytes[0]) |
                       (UInt32(patched.bytes[1]) << 8U) |
                       (UInt32(patched.bytes[2]) << 16U) |
                       (UInt32(patched.bytes[3]) << 24U);
    return a64_patch_u32(ref output, offset, word);
}

func a64_branch_symbol(ref output: A64CodeBuffer, symbol: String, link: Bool) -> Bool {
    if (symbol.length() == 0) { return false; }

    let offset: UInt32 = UInt32(output.bytes.length());
    let kind: A64RelocationKind = A64RelocationKind.Jump26;
    let word: UInt32 = 0x14000000U;

    if link {
        kind = A64RelocationKind.Call26;
        word = 0x94000000U;
    }
    a64_emit_u32(ref output, word);
    output.relocations.append(A64Relocation(section=".text", offset=offset, kind=kind, symbol=symbol, addend=0L));

    return true;
}

func a64_symbol_address(ref output: A64CodeBuffer, destination: A64Register, symbol: String, addend: Long) -> Bool {
// ADRP obtains the page and ADD applies the low 12 bits. Keeping the pair in
// the object lets the linker relax or move the symbol without text fixups.
    let rd: Int = a64_gpr_code(destination);
    if (rd < 0 || destination == A64Register.SP || symbol.length() == 0) { return false; }

    let page_offset: UInt32 = UInt32(output.bytes.length());
    a64_emit_u32(ref output, 0x90000000U | UInt32(rd));
    output.relocations.append(A64Relocation(section=".text", offset=page_offset, kind=A64RelocationKind.Page21, symbol=symbol, addend=addend));

    let low_offset: UInt32 = UInt32(output.bytes.length());
    let add: UInt32 = 0x91000000U | UInt32(rd << 5) | UInt32(rd);
    a64_emit_u32(ref output, add);
    output.relocations.append(A64Relocation(section=".text", offset=low_offset, kind=A64RelocationKind.PageOffset12, symbol=symbol, addend=addend));

    return true;
}

func a64_enter_frame(ref output: A64CodeBuffer) -> Void {
// stp x29, x30, [sp, #-16]!; mov x29, sp
    a64_emit_u32(ref output, 0xA9BF7BFDU);
    a64_emit_u32(ref output, 0x910003FDU);
}

func a64_leave_frame(ref output: A64CodeBuffer) -> Void {
// ldp x29, x30, [sp], #16; ret
    a64_emit_u32(ref output, 0xA8C17BFDU);
    a64_emit_u32(ref output, 0xD65F03C0U);
}

func a64_enter_sized_frame(ref output: A64CodeBuffer, frame_size: Int) -> Bool {
    if (frame_size < 0 || frame_size > 4095 || frame_size % 16 != 0) { return false; }

    a64_enter_frame(ref output);
    if (frame_size != 0 && !a64_sub_immediate(ref output, A64Register.SP, A64Register.SP, frame_size, true)) {
        return false;
    }

    return true;
}

func a64_leave_sized_frame(ref output: A64CodeBuffer, frame_size: Int) -> Bool {
    if (frame_size < 0 || frame_size > 4095 || frame_size % 16 != 0) { return false; }

    if (frame_size != 0 && !a64_add_immediate(ref output, A64Register.SP, A64Register.SP, frame_size, true)) {
        return false;
    }
    a64_leave_frame(ref output);

    return true;
}
