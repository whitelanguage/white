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

func x86_emit_i32(ref output: X86CodeBuffer, value: Int) -> Void {
    let encoded = Long(value);
    if (encoded < 0L) {
        encoded += 4294967296L;
    }

    x86_emit_u32(ref output, UInt32(encoded));
}

func x86_patch_i32(ref output: X86CodeBuffer, offset: Int, value: Int) -> Bool {
    if (offset < 0 || offset + 4 > output.bytes.length()) {
        return false;
    }

    let encoded = Long(value);
    if (encoded < 0L) {
        encoded += 4294967296L;
    }

    let bits = UInt32(encoded);
    output.bytes[offset] = Byte(bits & 255U);
    output.bytes[offset + 1] = Byte((bits >> 8U) & 255U);
    output.bytes[offset + 2] = Byte((bits >> 16U) & 255U);
    output.bytes[offset + 3] = Byte((bits >> 24U) & 255U);

    return true;
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

func x86_modrm_group(group: Int, rm: X86Register) -> Byte {
    return Byte(192 | ((group & 7) << 3) | (x86_register_code(rm) & 7));
}

func x86_mov_register_imm32(ref output: X86CodeBuffer, destination: X86Register, value: UInt32) -> Void {
    x86_rex(ref output, false, X86Register.None, X86Register.None, destination);
    x86_emit_byte(ref output, Byte(184 + x86_register_code(destination)));
    x86_emit_u32(ref output, value);
}

func x86_mov_register32(ref output: X86CodeBuffer, destination: X86Register, source: X86Register) -> Void {
    x86_rex(ref output, false, source, X86Register.None, destination);
    x86_emit_byte(ref output, Byte(137));
    x86_emit_byte(ref output, x86_modrm_register(source, destination));
}

func x86_mov_eax_imm32(ref output: X86CodeBuffer, value: UInt32) -> Void {
    x86_mov_register_imm32(ref output, X86Register.RAX, value);
}

func x86_mov_rax_imm64(ref output: X86CodeBuffer, value: UInt64) -> Void {
    x86_emit_byte(ref output, Byte(72));
    x86_emit_byte(ref output, Byte(184));
    x86_emit_u64(ref output, value);
}

func x86_mov_eax_register32(ref output: X86CodeBuffer, source: X86Register) -> Void {
    if (x86_register_code(source) < 0) { return; }
    x86_mov_register32(ref output, X86Register.RAX, source);
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

func x86_add_register32(ref output: X86CodeBuffer, destination: X86Register, source: X86Register) -> Void {
    x86_rex(ref output, false, source, X86Register.None, destination);
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

func x86_sub_register32(ref output: X86CodeBuffer, destination: X86Register, source: X86Register) -> Void {
    x86_rex(ref output, false, source, X86Register.None, destination);
    x86_emit_byte(ref output, Byte(41));
    x86_emit_byte(ref output, x86_modrm_register(source, destination));
}

func x86_imul_register32(ref output: X86CodeBuffer, destination: X86Register, source: X86Register) -> Void {
    x86_rex(ref output, false, destination, X86Register.None, source);
    x86_emit_byte(ref output, Byte(15));
    x86_emit_byte(ref output, Byte(175));
    x86_emit_byte(ref output, x86_modrm_register(destination, source));
}

func x86_add_eax_imm32(ref output: X86CodeBuffer, value: UInt32) -> Void {
    x86_add_register_imm32(ref output, X86Register.RAX, value);
}

func x86_add_register_imm32(ref output: X86CodeBuffer, destination: X86Register, value: UInt32) -> Void {
    x86_rex(ref output, false, X86Register.None, X86Register.None, destination);
    x86_emit_byte(ref output, Byte(129));
    x86_emit_byte(ref output, x86_modrm_group(0, destination));
    x86_emit_u32(ref output, value);
}

func x86_sub_eax_imm32(ref output: X86CodeBuffer, value: UInt32) -> Void {
    x86_sub_register_imm32(ref output, X86Register.RAX, value);
}

func x86_sub_register_imm32(ref output: X86CodeBuffer, destination: X86Register, value: UInt32) -> Void {
    x86_rex(ref output, false, X86Register.None, X86Register.None, destination);
    x86_emit_byte(ref output, Byte(129));
    x86_emit_byte(ref output, x86_modrm_group(5, destination));
    x86_emit_u32(ref output, value);
}

func x86_imul_eax_imm32(ref output: X86CodeBuffer, value: UInt32) -> Void {
    x86_imul_register_imm32(ref output, X86Register.RAX, value);
}

func x86_imul_register_imm32(ref output: X86CodeBuffer, destination: X86Register, value: UInt32) -> Void {
    x86_rex(ref output, false, destination, X86Register.None, destination);
    x86_emit_byte(ref output, Byte(105));
    x86_emit_byte(ref output, x86_modrm_register(destination, destination));
    x86_emit_u32(ref output, value);
}

func x86_cmp_eax_imm32(ref output: X86CodeBuffer, value: UInt32) -> Void {
    x86_cmp_register_imm32(ref output, X86Register.RAX, value);
}

func x86_cmp_register_imm32(ref output: X86CodeBuffer, register: X86Register, value: UInt32) -> Void {
    if (register == X86Register.RAX) {
        x86_emit_byte(ref output, Byte(61));
        x86_emit_u32(ref output, value);
        return;
    }
    x86_rex(ref output, false, X86Register.None, X86Register.None, register);
    x86_emit_byte(ref output, Byte(129));
    x86_emit_byte(ref output, x86_modrm_group(7, register));
    x86_emit_u32(ref output, value);
}

func x86_cmp_register32(ref output: X86CodeBuffer, left: X86Register, right: X86Register) -> Void {
    x86_rex(ref output, false, right, X86Register.None, left);
    x86_emit_byte(ref output, Byte(57));
    x86_emit_byte(ref output, x86_modrm_register(right, left));
}

func x86_jump_rel32(ref output: X86CodeBuffer) -> Int {
    x86_emit_byte(ref output, Byte(233));
    let patch_offset: Int = output.bytes.length();
    x86_emit_u32(ref output, 0U);

    return patch_offset;
}

func x86_call_rel32(ref output: X86CodeBuffer) -> Int {
    x86_emit_byte(ref output, Byte(232));
    let patch_offset: Int = output.bytes.length();
    x86_emit_u32(ref output, 0U);

    return patch_offset;
}

func x86_jump_if_rel32(ref output: X86CodeBuffer, opcode: X86Opcode) -> Int {
    let code: Byte = Byte(0);
    if (opcode == X86Opcode.Je)       { code = Byte(132); }
    else if (opcode == X86Opcode.Jne) { code = Byte(133); }
    else if (opcode == X86Opcode.Jl)  { code = Byte(140); }
    else if (opcode == X86Opcode.Jle) { code = Byte(142); }
    else if (opcode == X86Opcode.Jg)  { code = Byte(143); }
    else if (opcode == X86Opcode.Jge) { code = Byte(141); }
    else if (opcode == X86Opcode.Ja)  { code = Byte(135); }
    else if (opcode == X86Opcode.Jae) { code = Byte(131); }
    else if (opcode == X86Opcode.Jb)  { code = Byte(130); }
    else if (opcode == X86Opcode.Jbe) { code = Byte(134); }
    else { return -1; }

    x86_emit_byte(ref output, Byte(15));
    x86_emit_byte(ref output, code);
    let patch_offset: Int = output.bytes.length();
    x86_emit_u32(ref output, 0U);

    return patch_offset;
}

func x86_push_rbp(ref output: X86CodeBuffer) -> Void {
    x86_emit_byte(ref output, Byte(85));
}

func x86_pop_rbp(ref output: X86CodeBuffer) -> Void {
    x86_emit_byte(ref output, Byte(93));
}

func x86_mov_rbp_rsp(ref output: X86CodeBuffer) -> Void {
    x86_emit_byte(ref output, Byte(72));
    x86_emit_byte(ref output, Byte(137));
    x86_emit_byte(ref output, Byte(229));
}

func x86_mov_rsp_rbp(ref output: X86CodeBuffer) -> Void {
    x86_emit_byte(ref output, Byte(72));
    x86_emit_byte(ref output, Byte(137));
    x86_emit_byte(ref output, Byte(236));
}

func x86_sub_rsp_imm32(ref output: X86CodeBuffer, value: UInt32) -> Void {
    x86_emit_byte(ref output, Byte(72));
    x86_emit_byte(ref output, Byte(129));
    x86_emit_byte(ref output, Byte(236));
    x86_emit_u32(ref output, value);
}

func x86_store_eax_rbp_disp32(ref output: X86CodeBuffer, displacement: Int) -> Void {
    x86_store_register32_rbp_disp32(ref output, X86Register.RAX, displacement);
}

func x86_store_register32_rbp_disp32(ref output: X86CodeBuffer, source: X86Register, displacement: Int) -> Void {
    x86_store_register32_base_disp32(ref output, source, X86Register.RBP, displacement);
}

func x86_load_eax_rbp_disp32(ref output: X86CodeBuffer, displacement: Int) -> Void {
    x86_load_register32_rbp_disp32(ref output, X86Register.RAX, displacement);
}

func x86_load_register32_rbp_disp32(ref output: X86CodeBuffer, destination: X86Register, displacement: Int) -> Void {
    x86_load_register32_base_disp32(ref output, destination, X86Register.RBP, displacement);
}

func x86_store_register32_base_disp32(ref output: X86CodeBuffer, source: X86Register, base: X86Register, displacement: Int) -> Void {
    let base_code: Int = x86_register_code(base);
    let source_code: Int = x86_register_code(source);
    if (base_code < 0 || source_code < 0) {
        return;
    }

    x86_rex(ref output, false, source, X86Register.None, base);
    x86_emit_byte(ref output, Byte(137));
    x86_emit_byte(ref output, Byte(128 | ((source_code & 7) << 3) | (base_code & 7)));

    if ((base_code & 7) == 4) {
        x86_emit_byte(ref output, Byte(36));
    }

    x86_emit_i32(ref output, displacement);
}

func x86_load_register32_base_disp32(ref output: X86CodeBuffer, destination: X86Register, base: X86Register, displacement: Int) -> Void {
    let base_code: Int = x86_register_code(base);
    let destination_code: Int = x86_register_code(destination);
    if (base_code < 0 || destination_code < 0) {
        return;
    }

    x86_rex(ref output, false, destination, X86Register.None, base);
    x86_emit_byte(ref output, Byte(139));
    x86_emit_byte(ref output, Byte(128 | ((destination_code & 7) << 3) | (base_code & 7)));

    if ((base_code & 7) == 4) {
        x86_emit_byte(ref output, Byte(36));
    }

    x86_emit_i32(ref output, displacement);
}

func x86_frame_enter(ref output: X86CodeBuffer, size: Int) -> Void {
    x86_push_rbp(ref output);
    x86_mov_rbp_rsp(ref output);
    if (size > 0) {
        x86_sub_rsp_imm32(ref output, UInt32(size));
    }
}

func x86_frame_leave(ref output: X86CodeBuffer) -> Void {
    x86_mov_rsp_rbp(ref output);
    x86_pop_rbp(ref output);
}

func x86_return(ref output: X86CodeBuffer) -> Void {
    x86_emit_byte(ref output, Byte(195));
}
