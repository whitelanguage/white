// src/compiler/machine/aarch64/wide.wl
import * from "model.wl"
import * from "../../wir/model.wl"
import * from "encoder.wl"
import * from "allocator.wl"


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
        if (!a64_shift_register(ref output, destination.high, destination.high, count, 0, true) ||
            !a64_shift_register(ref output, cross, destination.low, work, 2, true) ||
            !a64_logical_register(ref output, destination.high, destination.high, cross, 1, true) ||
            !a64_shift_register(ref output, destination.low, destination.low, count, 0, true)) {
            return false;
        }
    } else {
        let high_shift: Int = 2;
        if (opcode == WirOpcode.SignedShiftRight) { high_shift = 1; }
        if (!a64_shift_register(ref output, destination.low, destination.low, count, 2, true) ||
            !a64_shift_register(ref output, cross, destination.high, work, 0, true) ||
            !a64_logical_register(ref output, destination.low, destination.low, cross, 1, true) ||
            !a64_shift_register(ref output, destination.high, destination.high, count, high_shift, true)) {
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
        if (!a64_shift_register(ref output, destination.high, destination.low, count, 0, true) ||
            !a64_mov_immediate(ref output, destination.low, 0UL, true)) {
            return false;
        }
    } else {
        let low_shift: Int = 2;
        if (opcode == WirOpcode.SignedShiftRight) { low_shift = 1; }
        if (!a64_shift_register(ref output, destination.low, destination.high, count, low_shift, true)) {
            return false;
        }
        if (opcode == WirOpcode.SignedShiftRight) {
            if (!a64_mov_immediate(ref output, work, 63UL, true) ||
                !a64_shift_register(ref output, destination.high, destination.high, work, 1, true)) {
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
