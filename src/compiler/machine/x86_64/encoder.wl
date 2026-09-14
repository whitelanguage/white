// compiler/machine/x86_64/encoder.wl
import * from "model.wl"


struct X86CodeBuffer(bytes: Vector(Byte))


func x86_new_code_buffer() -> X86CodeBuffer {
    return X86CodeBuffer(bytes=[]);
}

func x86_emit_byte(ref output: X86CodeBuffer, value: Byte) -> Void {
    output.bytes.append(value);
}

func x86_emit_u32(ref output: X86CodeBuffer, value: UInt32) -> Void {
    x86_emit_byte(ref output, Byte(value & 255U));
    x86_emit_byte(ref output, Byte((value >> 8U) & 255U));
    x86_emit_byte(ref output, Byte((value >> 16U) & 255U));
    x86_emit_byte(ref output, Byte((value >> 24U) & 255U));
}

func x86_emit_u64(ref output: X86CodeBuffer, value: UInt64) -> Void {
    x86_emit_u32(ref output, UInt32(value & 4294967295UL));
    x86_emit_u32(ref output, UInt32((value >> 32U) & 4294967295UL));
}

func x86_register_code(register: X86Register) -> Int {
    if (register == X86Register.RAX) { return 0; }
    if (register == X86Register.RBX) { return 3; }
    if (register == X86Register.RCX) { return 1; }
    if (register == X86Register.RDX) { return 2; }
    if (register == X86Register.RSI) { return 6; }
    if (register == X86Register.RDI) { return 7; }
    if (register == X86Register.RBP) { return 5; }
    if (register == X86Register.RSP) { return 4; }
    if (register == X86Register.R8 || register == X86Register.R9 || register == X86Register.R10 || register == X86Register.R11 ||
        register == X86Register.R12 || register == X86Register.R13 || register == X86Register.R14 || register == X86Register.R15) {
        return Int(register) - Int(X86Register.R8);
    }
    return -1;
}

func x86_register_extended(register: X86Register) -> Bool {
    return register == X86Register.R8 || register == X86Register.R9 || register == X86Register.R10 || register == X86Register.R11 ||
           register == X86Register.R12 || register == X86Register.R13 || register == X86Register.R14 || register == X86Register.R15;
}

func x86_rex(ref output: X86CodeBuffer, wide: Bool, reg: X86Register, index: X86Register, base: X86Register) -> Void {
    let bits: Int = 0;

    if wide {
        bits |= 8;
    }
    if (x86_register_extended(reg)) {
        bits |= 4;
    }
    if (x86_register_extended(index)) {
        bits |= 2;
    }
    if (x86_register_extended(base)) {
        bits |= 1;
    }

    let prefix: Byte = Byte(64 | bits);
    if (prefix != Byte(64)) {
        x86_emit_byte(ref output, prefix);
    }

}

func x86_modrm_register(reg: X86Register, rm: X86Register) -> Byte {
    let reg_code: Int = x86_register_code(reg);
    let rm_code: Int = x86_register_code(rm);

    return Byte(192 | ((reg_code & 7) << 3) | (rm_code & 7));
}

func x86_mov_eax_imm32(ref output: X86CodeBuffer, value: UInt32) -> Void {
    x86_emit_byte(ref output, Byte(184));
    x86_emit_u32(ref output, value);
}

func x86_mov_rax_imm64(ref output: X86CodeBuffer, value: UInt64) -> Void {
    x86_emit_byte(ref output, Byte(72));
    x86_emit_byte(ref output, Byte(184));
    x86_emit_u64(ref output, value);
}

func x86_mov_eax_register32(ref output: X86CodeBuffer, source: X86Register) -> Void {
    if (x86_register_code(source) < 0) { return; }

    x86_rex(ref output, false, source, X86Register.None, X86Register.RAX);
    x86_emit_byte(ref output, Byte(137));
    x86_emit_byte(ref output, x86_modrm_register(source, X86Register.RAX));
}

func x86_mov_register(ref output: X86CodeBuffer, destination: X86Register, source: X86Register) -> Void? {
    if (x86_register_code(destination) < 0 || x86_register_code(source) < 0) {
        throw Error.InvalidArgument;
    }

    x86_rex(ref output, true, source, X86Register.None, destination);
    x86_emit_byte(ref output, Byte(137));
    x86_emit_byte(ref output, x86_modrm_register(source, destination));
}

func x86_add_register(ref output: X86CodeBuffer, destination: X86Register, source: X86Register) -> Void? {
    if (x86_register_code(destination) < 0 || x86_register_code(source) < 0) {
        throw Error.InvalidArgument;
    }

    x86_rex(ref output, true, source, X86Register.None, destination);
    x86_emit_byte(ref output, Byte(1));
    x86_emit_byte(ref output, x86_modrm_register(source, destination));
}

func x86_sub_register(ref output: X86CodeBuffer, destination: X86Register, source: X86Register) -> Void? {
    if (x86_register_code(destination) < 0 || x86_register_code(source) < 0) {
        throw Error.InvalidArgument;
    }

    x86_rex(ref output, true, source, X86Register.None, destination);
    x86_emit_byte(ref output, Byte(41));
    x86_emit_byte(ref output, x86_modrm_register(source, destination));
}

func x86_add_eax_imm32(ref output: X86CodeBuffer, value: UInt32) -> Void {
    x86_emit_byte(ref output, Byte(129));
    x86_emit_byte(ref output, Byte(192));
    x86_emit_u32(ref output, value);
}

func x86_sub_eax_imm32(ref output: X86CodeBuffer, value: UInt32) -> Void {
    x86_emit_byte(ref output, Byte(129));
    x86_emit_byte(ref output, Byte(232));
    x86_emit_u32(ref output, value);
}

func x86_imul_eax_imm32(ref output: X86CodeBuffer, value: UInt32) -> Void {
    x86_emit_byte(ref output, Byte(105));
    x86_emit_byte(ref output, Byte(192));
    x86_emit_u32(ref output, value);
}

func x86_return(ref output: X86CodeBuffer) -> Void {
    x86_emit_byte(ref output, Byte(195));
}
