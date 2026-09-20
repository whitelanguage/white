// compiler/machine/x86_64/sse.wl
import * from "model.wl"
import X86CodeBuffer, x86_emit_byte, x86_emit_i32, x86_register_code, x86_register_extended from "encoder.wl"

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
