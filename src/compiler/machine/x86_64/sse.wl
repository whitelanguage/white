// compiler/machine/x86_64/sse.wl
import * from "model.wl"
import X86CodeBuffer, x86_emit_byte, x86_emit_i32, x86_register_code, x86_register_extended, x86_mov_register64, x86_mov_register32, x86_mov_register_imm64, x86_mov_register_imm32, x86_bitwise_register_imm32, x86_shift_register_imm8, x86_or_register_width, x86_test_register_width, x86_jump_if_rel32, x86_jump_rel32, x86_patch_i32 from "encoder.wl"

func x86_xmm_code(register: X86Register) -> Int {
    if (!x86_is_xmm(register)) { return -1; }
    return Int(register) - Int(X86Register.XMM0);
}

func x86_sse_prefix(ref output: X86CodeBuffer, prefix: Int, wide: Bool, reg: Int, rm: Int) -> Void {
    // mandatory SSE prefixes precede REX, whose bits extend the ModRM registers
    if (prefix != 0) { x86_emit_byte(ref output, Byte(prefix)); }
    let rex: Int = 64;
    if (wide) { rex |= 8; }
    if (reg >= 8) { rex |= 4; }
    if (rm >= 8) { rex |= 1; }
    if (rex != 64) { x86_emit_byte(ref output, Byte(rex)); }
    x86_emit_byte(ref output, Byte(15));
}

func x86_sse_memory(ref output: X86CodeBuffer, opcode: Int, xmm: X86Register, base: X86Register, offset: Int, size: Int) -> Bool {
    let reg: Int = x86_xmm_code(xmm);
    let rm: Int = x86_register_code(base);
    if (reg < 0 || rm < 0 || (size != 4 && size != 8)) { return false; }
    if (x86_register_extended(base)) { rm += 8; }
    let prefix: Int = 243;
    if (size == 8) { prefix = 242; }
    x86_sse_prefix(ref output, prefix, false, reg, rm);
    x86_emit_byte(ref output, Byte(opcode));
    x86_emit_byte(ref output, Byte(128 | ((reg & 7) << 3) | (rm & 7)));
    if ((rm & 7) == 4) { x86_emit_byte(ref output, Byte(36)); }
    x86_emit_i32(ref output, offset);
    return true;
}

func x86_sse_register(ref output: X86CodeBuffer, opcode: Int, destination: X86Register, source: X86Register, size: Int) -> Bool {
    let reg: Int = x86_xmm_code(destination);
    let rm: Int = x86_xmm_code(source);
    if (reg < 0 || rm < 0 || (size != 4 && size != 8)) { return false; }
    let prefix: Int = 243;
    if (size == 8) { prefix = 242; }
    x86_sse_prefix(ref output, prefix, false, reg, rm);
    x86_emit_byte(ref output, Byte(opcode));
    x86_emit_byte(ref output, Byte(192 | ((reg & 7) << 3) | (rm & 7)));
    return true;
}

func x86_sse_bits(ref output: X86CodeBuffer, xmm: X86Register, integer: X86Register, size: Int, to_xmm: Bool) -> Bool {
    let reg: Int = x86_xmm_code(xmm);
    let rm: Int = x86_register_code(integer);
    if (reg < 0 || rm < 0 || (size != 4 && size != 8)) { return false; }
    if (x86_register_extended(integer)) { rm += 8; }
    x86_sse_prefix(ref output, 102, size == 8, reg, rm);
    let opcode: Int = 126;
    if (to_xmm) { opcode = 110; }
    x86_emit_byte(ref output, Byte(opcode));
    x86_emit_byte(ref output, Byte(192 | ((reg & 7) << 3) | (rm & 7)));
    return true;
}

func x86_sse_compare(ref output: X86CodeBuffer, left: X86Register, right: X86Register, size: Int) -> Bool {
    let reg: Int = x86_xmm_code(left);
    let rm: Int = x86_xmm_code(right);
    if (reg < 0 || rm < 0 || (size != 4 && size != 8)) { return false; }
    let prefix = 0;
    if (size == 8) { prefix = 102; }
    x86_sse_prefix(ref output, prefix, false, reg, rm);
    x86_emit_byte(ref output, Byte(46));
    x86_emit_byte(ref output, Byte(192 | ((reg & 7) << 3) | (rm & 7)));
    return true;
}

func x86_sse_convert(ref output: X86CodeBuffer, destination: X86Register, source: X86Register, float_size: Int, integer_size: Int, to_float: Bool) -> Bool {
    // CVTT truncates independently of MXCSR; integer inputs have already been extended
    let reg: Int = x86_register_code(destination);
    let rm = x86_xmm_code(source);
    let opcode = 44;
    if (to_float) {
        reg = x86_xmm_code(destination);
        rm = x86_register_code(source);
        opcode = 42;
        if (x86_register_extended(source)) { rm += 8; }
    } else if (x86_register_extended(destination)) {
        reg += 8;
    }
    if (reg < 0 || rm < 0 || (float_size != 4 && float_size != 8) || (integer_size != 4 && integer_size != 8)) { return false; }
    let prefix = 243;
    if (float_size == 8) { prefix = 242; }
    x86_sse_prefix(ref output, prefix, integer_size == 8, reg, rm);
    x86_emit_byte(ref output, Byte(opcode));
    x86_emit_byte(ref output, Byte(192 | ((reg & 7) << 3) | (rm & 7)));
    return true;
}

func x86_uint64_to_float(ref output: X86CodeBuffer, destination: X86Register, source: X86Register, half: X86Register, low_bit: X86Register, size: Int) -> Bool {
    // above INT64_MAX, convert (x >> 1) | (x & 1), then double
    // retaining the low bit prevents rounding a value just above a tie downwards
    if (source == half || source == low_bit || half == low_bit || x86_register_code(source) < 0 ||
        x86_register_code(half) < 0 || x86_register_code(low_bit) < 0 || x86_xmm_code(destination) < 0 || (size != 4 && size != 8)) { return false; }
    x86_test_register_width(ref output, source, source, true);
    let small: Int = x86_jump_if_rel32(ref output, X86Opcode.Jge);
    x86_mov_register64(ref output, half, source);
    x86_mov_register32(ref output, low_bit, source);
    x86_bitwise_register_imm32(ref output, low_bit, 1U, 4);
    x86_shift_register_imm8(ref output, half, Byte(1), 5, true);
    x86_or_register_width(ref output, half, low_bit, true);
    if (!x86_sse_convert(ref output, destination, half, size, 8, true) ||
        !x86_sse_register(ref output, 88, destination, destination, size)) { return false; }
    let done: Int = x86_jump_rel32(ref output);
    if (!x86_patch_i32(ref output, small, output.bytes.length() - (small + 4))) { return false; }
    if (!x86_sse_convert(ref output, destination, source, size, 8, true)) { return false; }
    return x86_patch_i32(ref output, done, output.bytes.length() - (done + 4));
}

func x86_float_to_uint64(ref output: X86CodeBuffer, destination: X86Register, source: X86Register, threshold: X86Register, temporary: X86Register, size: Int) -> Bool {
    // source is scratch: its allocator binding must be preserved before emission
    // subtracting 2^63 is exact in the upper half of the valid u64 range
    if (source == threshold || destination == temporary || x86_xmm_code(source) < 0 || x86_xmm_code(threshold) < 0 ||
        x86_register_code(destination) < 0 || x86_register_code(temporary) < 0 || (size != 4 && size != 8)) { return false; }
    if (size == 8) { x86_mov_register_imm64(ref output, temporary, 0x43E0000000000000UL); }
    else { x86_mov_register_imm32(ref output, temporary, 0x5F000000U); }
    if (!x86_sse_bits(ref output, threshold, temporary, size, true) ||
        !x86_sse_compare(ref output, source, threshold, size)) { return false; }
    let small: Int = x86_jump_if_rel32(ref output, X86Opcode.Jb);
    if (!x86_sse_register(ref output, 92, source, threshold, size) ||
        !x86_sse_convert(ref output, destination, source, size, 8, false)) { return false; }
    x86_mov_register_imm64(ref output, temporary, 9223372036854775808UL);
    x86_or_register_width(ref output, destination, temporary, true);
    let done: Int = x86_jump_rel32(ref output);
    if (!x86_patch_i32(ref output, small, output.bytes.length() - (small + 4))) { return false; }
    if (!x86_sse_convert(ref output, destination, source, size, 8, false)) { return false; }
    return x86_patch_i32(ref output, done, output.bytes.length() - (done + 4));
}
