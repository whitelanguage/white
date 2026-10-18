// src/compiler/machine/x86_64/wide.wl
import * from "model.wl"
import * from "../../wir/model.wl"
import * from "encoder.wl"
import * from "allocator.wl"


func x86_shift_wide_immediate(ref output: X86CodeBuffer, opcode: WirOpcode, amount: Int) -> Void {
    amount &= 127;
    if (amount < 64) {
        if (opcode == WirOpcode.ShiftLeft) {
            x86_shift_double_imm8(ref output, X86Register.R10, X86Register.RAX, Byte(amount), true);
            x86_shift_register_imm8(ref output, X86Register.RAX, Byte(amount), 4, true);
        } else {
            x86_shift_double_imm8(ref output, X86Register.RAX, X86Register.R10, Byte(amount), false);
            let group: Int = 5;
            if (opcode == WirOpcode.SignedShiftRight) { group = 7; }
            x86_shift_register_imm8(ref output, X86Register.R10, Byte(amount), group, true);
        }
        return;
    }
    let remaining: Byte = Byte(amount - 64);
    if (opcode == WirOpcode.ShiftLeft) {
        x86_mov_register64(ref output, X86Register.R10, X86Register.RAX);
        x86_shift_register_imm8(ref output, X86Register.R10, remaining, 4, true);
        x86_mov_register_imm32(ref output, X86Register.RAX, 0U);
    } else {
        x86_mov_register64(ref output, X86Register.RAX, X86Register.R10);
        let group: Int = 5;
        if (opcode == WirOpcode.SignedShiftRight) { group = 7; }
        x86_shift_register_imm8(ref output, X86Register.RAX, remaining, group, true);
        if (opcode == WirOpcode.SignedShiftRight) {
            x86_shift_register_imm8(ref output, X86Register.R10, Byte(63), 7, true);
        }
        else {
            x86_mov_register_imm32(ref output, X86Register.R10, 0U);
        }
    }
}

func x86_shift_wide_variable(ref output: X86CodeBuffer, opcode: WirOpcode) -> Bool {
    x86_bitwise_register_imm32(ref output, X86Register.RCX, 127U, 4);
    x86_test_register_width(ref output, X86Register.RCX, X86Register.RCX, true);
    let zero: Int = x86_jump_if_rel32(ref output, X86Opcode.Je);
    x86_mov_register64(ref output, X86Register.R11, X86Register.RCX);
    x86_bitwise_register_imm32(ref output, X86Register.R11, 64U, 4);
    x86_test_register_width(ref output, X86Register.R11, X86Register.R11, true);
    let large: Int = x86_jump_if_rel32(ref output, X86Opcode.Jne);
    if (opcode == WirOpcode.ShiftLeft) {
        x86_shift_double_cl(ref output, X86Register.R10, X86Register.RAX, true);
        x86_shift_register_cl(ref output, X86Register.RAX, 4, true);
    } else {
        x86_shift_double_cl(ref output, X86Register.RAX, X86Register.R10, false);
        let group: Int = 5;
        if (opcode == WirOpcode.SignedShiftRight) { group = 7; }
        x86_shift_register_cl(ref output, X86Register.R10, group, true);
    }
    let done: Int = x86_jump_rel32(ref output);
    if (!x86_patch_i32(ref output, large, output.bytes.length() - (large + 4))) { return false; }
    if (opcode == WirOpcode.ShiftLeft) {
        x86_mov_register64(ref output, X86Register.R10, X86Register.RAX);
        x86_shift_register_cl(ref output, X86Register.R10, 4, true);
        x86_mov_register_imm32(ref output, X86Register.RAX, 0U);
    } else {
        x86_mov_register64(ref output, X86Register.RAX, X86Register.R10);
        let group: Int = 5;
        if (opcode == WirOpcode.SignedShiftRight) { group = 7; }
        x86_shift_register_cl(ref output, X86Register.RAX, group, true);
        if (opcode == WirOpcode.SignedShiftRight) {
            x86_shift_register_imm8(ref output, X86Register.R10, Byte(63), 7, true);
        }
        else {
            x86_mov_register_imm32(ref output, X86Register.R10, 0U);
        }
    }
    if (!x86_patch_i32(ref output, done, output.bytes.length() - (done + 4))) { return false; }
    return x86_patch_i32(ref output, zero, output.bytes.length() - (zero + 4));
}

func x86_wide_low_comparison(opcode: WirOpcode) -> X86Opcode {
    if (opcode == WirOpcode.SignedLess || opcode == WirOpcode.UnsignedLess) { return X86Opcode.Jb; }
    if (opcode == WirOpcode.SignedLessEqual || opcode == WirOpcode.UnsignedLessEqual) {
        return X86Opcode.Jbe;
    }
    if (opcode == WirOpcode.SignedGreater || opcode == WirOpcode.UnsignedGreater) {
        return X86Opcode.Ja;
    }
    if (opcode == WirOpcode.SignedGreaterEqual || opcode == WirOpcode.UnsignedGreaterEqual) {
        return X86Opcode.Jae;
    }
    return X86Opcode.Invalid;
}

func x86_wide_high_comparison(opcode: WirOpcode) -> X86Opcode {
    if (opcode == WirOpcode.SignedLess || opcode == WirOpcode.SignedLessEqual) { return X86Opcode.Jl; }
    if (opcode == WirOpcode.SignedGreater || opcode == WirOpcode.SignedGreaterEqual) { return X86Opcode.Jg; }
    if (opcode == WirOpcode.UnsignedLess || opcode == WirOpcode.UnsignedLessEqual) {
        return X86Opcode.Jb;
    }
    if (opcode == WirOpcode.UnsignedGreater || opcode == WirOpcode.UnsignedGreaterEqual) {
        return X86Opcode.Ja;
    }
    return X86Opcode.Invalid;
}

func x86_divide_wide_unsigned(ref output: X86CodeBuffer) -> Bool {
// the 64-bit divisor path uses two hardware divisions, the general path
    // keeps the loop in emitted code instead of unrolling 128 quotient bits
    x86_test_register_width(ref output, X86Register.R9, X86Register.R9, true);
    let general: Int = x86_jump_if_rel32(ref output, X86Opcode.Jne);
    x86_mov_register64(ref output, X86Register.R8, X86Register.RAX);
    x86_mov_register64(ref output, X86Register.RAX, X86Register.R10);
    x86_mov_register_imm32(ref output, X86Register.RDX, 0U);
    x86_div_register_width(ref output, X86Register.R11, true, false);
    x86_mov_register64(ref output, X86Register.R10, X86Register.RAX);
    x86_mov_register64(ref output, X86Register.RAX, X86Register.R8);
    x86_div_register_width(ref output, X86Register.R11, true, false);
    x86_mov_register_imm32(ref output, X86Register.R8, 0U);
    let done: Int = x86_jump_rel32(ref output);

    if (!x86_patch_i32(ref output, general, output.bytes.length() - (general + 4))) { return false; }
    x86_mov_register_imm32(ref output, X86Register.RDX, 0U);
    x86_mov_register_imm32(ref output, X86Register.R8, 0U);
    x86_mov_register_imm32(ref output, X86Register.RCX, 128U);
    let loop: Int = output.bytes.length();
    x86_shift_register_imm8(ref output, X86Register.RAX, Byte(1), 4, true);
    x86_shift_register_imm8(ref output, X86Register.R10, Byte(1), 2, true);
    x86_shift_register_imm8(ref output, X86Register.RDX, Byte(1), 2, true);
    x86_shift_register_imm8(ref output, X86Register.R8, Byte(1), 2, true);
    x86_cmp_register64(ref output, X86Register.R8, X86Register.R9);
    let subtract_high: Int = x86_jump_if_rel32(ref output, X86Opcode.Ja);
    let skip_high: Int = x86_jump_if_rel32(ref output, X86Opcode.Jb);
    x86_cmp_register64(ref output, X86Register.RDX, X86Register.R11);
    let skip_low: Int = x86_jump_if_rel32(ref output, X86Opcode.Jb);
    if (!x86_patch_i32(ref output, subtract_high, output.bytes.length() - (subtract_high + 4))) {
        return false;
    }
    x86_sub_register64(ref output, X86Register.RDX, X86Register.R11);
    x86_sbb_register64(ref output, X86Register.R8, X86Register.R9);
    // A 32-bit OR would clear the upper half of RAX on every quotient bit.
    // It went unnoticed while the test values happened to keep the quotient small.
    x86_bitwise_register_imm(ref output, X86Register.RAX, 1U, 1, true);
    let next: Int = output.bytes.length();
    if (!x86_patch_i32(ref output, skip_high, next - (skip_high + 4)) ||
        !x86_patch_i32(ref output, skip_low, next - (skip_low + 4))) { return false; }
    x86_sub_register_imm32(ref output, X86Register.RCX, 1U);
    let repeat: Int = x86_jump_if_rel32(ref output, X86Opcode.Jne);
    if (!x86_patch_i32(ref output, repeat, loop - (repeat + 4))) { return false; }
    return x86_patch_i32(ref output, done, output.bytes.length() - (done + 4));
}

func x86_apply_wide_sign(ref output: X86CodeBuffer, low: X86Register, high: X86Register, mask: X86Register) -> Void {
    x86_xor_register_width(ref output, low, mask, true);
    x86_xor_register_width(ref output, high, mask, true);
    x86_sub_register64(ref output, low, mask);
    x86_sbb_register64(ref output, high, mask);
}
