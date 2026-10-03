// compiler/machine/x86_64/encoder.wl
import * from "model.wl"


struct X86CodeBuffer(bytes: Vector(Byte), relocations: Vector(X86Relocation))


func x86_new_code_buffer() -> X86CodeBuffer {
    return X86CodeBuffer(bytes=[], relocations=[]);
}

func x86_lea_symbol(ref output: X86CodeBuffer, destination: X86Register, symbol: String, addend: Long) -> Bool {
    if (x86_register_code(destination) < 0 || symbol.length() == 0 ||
        addend < -2147483648L || addend > 2147483647L) {
        return false;
    }

    // LEA with RIP-relative addressing leaves the linker one signed rel32 field to fix.
    x86_rex(ref output, true, destination, X86Register.None, X86Register.None);
    x86_emit_byte(ref output, Byte(141));
    x86_emit_byte(ref output, Byte(5 | (x86_register_code(destination) << 3)));
    output.relocations.append(X86Relocation(section=".text", offset=UInt32(output.bytes.length()), kind=X86RelocationKind.Rel32, symbol=symbol, addend=addend));
    x86_emit_i32(ref output, Int(addend));
    return true;
}

func x86_emit_byte(ref output: X86CodeBuffer, value: Byte) -> Void {
    output.bytes.append(value);
}

func x86_emit_u32(ref output: X86CodeBuffer, value: UInt32) -> Void {
    // x86 immediates and displacements are little endian.
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
    // the low three bits come from the original eight-register encoding. R8-R15
    // reuse 0-7 and are selected by the matching REX bit.
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
    // REX is 0100WRXB. A bare 0x40 prefix is emitted elsewhere only when an
    // 8-bit instruction must select SIL/DIL/BPL/SPL instead of AH/CH/DH/BH.
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

func x86_mov_register_imm64(ref output: X86CodeBuffer, destination: X86Register, value: UInt64) -> Void {
    x86_rex(ref output, true, X86Register.None, X86Register.None, destination);
    x86_emit_byte(ref output, Byte(184 + x86_register_code(destination)));
    x86_emit_u64(ref output, value);
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
    x86_mov_register_imm64(ref output, X86Register.RAX, value);
}

func x86_mov_register64(ref output: X86CodeBuffer, destination: X86Register, source: X86Register) -> Void {
    x86_rex(ref output, true, source, X86Register.None, destination);
    x86_emit_byte(ref output, Byte(137));
    x86_emit_byte(ref output, x86_modrm_register(source, destination));
}

func x86_sign_extend32(ref output: X86CodeBuffer, destination: X86Register, source: X86Register) -> Void {
    x86_rex(ref output, true, destination, X86Register.None, source);
    x86_emit_byte(ref output, Byte(99));
    x86_emit_byte(ref output, x86_modrm_register(destination, source));
}

func x86_lea(ref output: X86CodeBuffer, destination: X86Register, base: X86Register, index: X86Register, scale: Int, displacement: Int) -> Bool {
    let base_code: Int = x86_register_code(base);
    let destination_code: Int = x86_register_code(destination);
    if (base_code < 0 || destination_code < 0) {
        return false;
    }

    let shift: Int = 0;
    if (scale == 2) { shift = 1; }
    else if (scale == 4) { shift = 2; }
    else if (scale == 8) { shift = 3; }
    else if (scale != 1) {
        return false;
    }

    // SIB index 4 means no index. RSP has the same low code, so it cannot be used
    // as an index here. A base with code 4 needs a SIB byte even without an index.
    let index_code: Int = 4;
    if (index != X86Register.None) {
        index_code = x86_register_code(index);
        if (index_code < 0 || index == X86Register.RSP) {
            return false;
        }
    }
    x86_rex(ref output, true, destination, index, base);
    x86_emit_byte(ref output, Byte(141));
    let sib: Bool = index != X86Register.None || base_code == 4;
    let rm: Int = base_code;
    if (sib) {
        rm = 4;
    }
    x86_emit_byte(ref output, Byte(128 | (destination_code << 3) | rm));
    if (sib) {
        x86_emit_byte(ref output, Byte((shift << 6) | (index_code << 3) | base_code));
    }
    x86_emit_i32(ref output, displacement);
    return true;
}

func x86_multiply_imm32(ref output: X86CodeBuffer, register: X86Register, value: UInt32, wide: Bool) -> Void {
    x86_rex(ref output, wide, register, X86Register.None, register);
    x86_emit_byte(ref output, Byte(105));
    x86_emit_byte(ref output, x86_modrm_register(register, register));
    x86_emit_u32(ref output, value);
}

func x86_extend_register(ref output: X86CodeBuffer, destination: X86Register, source: X86Register, size: Int, signed: Bool) -> Void {
    if (size != 1 && size != 2) { return; }
    x86_rex(ref output, false, destination, X86Register.None, source);
    if (size == 1 && !x86_register_extended(destination) && !x86_register_extended(source) && x86_register_code(source) >= 4) {
        x86_emit_byte(ref output, Byte(64));
    }
    x86_emit_byte(ref output, Byte(15));
    if (size == 1) {
        if (signed) { x86_emit_byte(ref output, Byte(190)); } else { x86_emit_byte(ref output, Byte(182)); }
    } else {
        if (signed) { x86_emit_byte(ref output, Byte(191)); } else { x86_emit_byte(ref output, Byte(183)); }
    }
    x86_emit_byte(ref output, x86_modrm_register(destination, source));
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

func x86_add_register64(ref output: X86CodeBuffer, destination: X86Register, source: X86Register) -> Void {
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

func x86_sub_register32(ref output: X86CodeBuffer, destination: X86Register, source: X86Register) -> Void {
    x86_rex(ref output, false, source, X86Register.None, destination);
    x86_emit_byte(ref output, Byte(41));
    x86_emit_byte(ref output, x86_modrm_register(source, destination));
}

func x86_sub_register64(ref output: X86CodeBuffer, destination: X86Register, source: X86Register) -> Void {
    x86_rex(ref output, true, source, X86Register.None, destination);
    x86_emit_byte(ref output, Byte(41));
    x86_emit_byte(ref output, x86_modrm_register(source, destination));
}

func x86_adc_register64(ref output: X86CodeBuffer, destination: X86Register, source: X86Register) -> Void {
    x86_rex(ref output, true, source, X86Register.None, destination);
    x86_emit_byte(ref output, Byte(17));
    x86_emit_byte(ref output, x86_modrm_register(source, destination));
}

func x86_sbb_register64(ref output: X86CodeBuffer, destination: X86Register, source: X86Register) -> Void {
    x86_rex(ref output, true, source, X86Register.None, destination);
    x86_emit_byte(ref output, Byte(25));
    x86_emit_byte(ref output, x86_modrm_register(source, destination));
}

func x86_imul_register32(ref output: X86CodeBuffer, destination: X86Register, source: X86Register) -> Void {
    x86_rex(ref output, false, destination, X86Register.None, source);
    x86_emit_byte(ref output, Byte(15));
    x86_emit_byte(ref output, Byte(175));
    x86_emit_byte(ref output, x86_modrm_register(destination, source));
}

func x86_imul_register64(ref output: X86CodeBuffer, destination: X86Register, source: X86Register) -> Void {
    x86_rex(ref output, true, destination, X86Register.None, source);
    x86_emit_byte(ref output, Byte(15));
    x86_emit_byte(ref output, Byte(175));
    x86_emit_byte(ref output, x86_modrm_register(destination, source));
}

func x86_mul_register64(ref output: X86CodeBuffer, source: X86Register) -> Void {
    x86_rex(ref output, true, X86Register.None, X86Register.None, source);
    x86_emit_byte(ref output, Byte(247));
    x86_emit_byte(ref output, x86_modrm_group(4, source));
}

func x86_and_register_width(ref output: X86CodeBuffer, destination: X86Register, source: X86Register, wide: Bool) -> Void {
    x86_rex(ref output, wide, source, X86Register.None, destination);
    x86_emit_byte(ref output, Byte(33));
    x86_emit_byte(ref output, x86_modrm_register(source, destination));
}

func x86_or_register_width(ref output: X86CodeBuffer, destination: X86Register, source: X86Register, wide: Bool) -> Void {
    x86_rex(ref output, wide, source, X86Register.None, destination);
    x86_emit_byte(ref output, Byte(9));
    x86_emit_byte(ref output, x86_modrm_register(source, destination));
}

func x86_xor_register_width(ref output: X86CodeBuffer, destination: X86Register, source: X86Register, wide: Bool) -> Void {
    x86_rex(ref output, wide, source, X86Register.None, destination);
    x86_emit_byte(ref output, Byte(49));
    x86_emit_byte(ref output, x86_modrm_register(source, destination));
}

func x86_bitwise_register_imm32(ref output: X86CodeBuffer, destination: X86Register, value: UInt32, group: Int) -> Void {
    x86_bitwise_register_imm(ref output, destination, value, group, false);
}

func x86_bitwise_register_imm(ref output: X86CodeBuffer, destination: X86Register, value: UInt32, group: Int, wide: Bool) -> Void {
    x86_rex(ref output, wide, X86Register.None, X86Register.None, destination);
    if (value <= 127U) {
        x86_emit_byte(ref output, Byte(131));
        x86_emit_byte(ref output, x86_modrm_group(group, destination));
        x86_emit_byte(ref output, Byte(value));
        return;
    }

    x86_emit_byte(ref output, Byte(129));
    x86_emit_byte(ref output, x86_modrm_group(group, destination));
    x86_emit_u32(ref output, value);
}

func x86_shift_register_imm8(ref output: X86CodeBuffer, register: X86Register, amount: Byte, group: Int, wide: Bool) -> Void {
    x86_rex(ref output, wide, X86Register.None, X86Register.None, register);
    x86_emit_byte(ref output, Byte(193));
    x86_emit_byte(ref output, x86_modrm_group(group, register));
    x86_emit_byte(ref output, amount);
}

func x86_shift_register_cl(ref output: X86CodeBuffer, register: X86Register, group: Int, wide: Bool) -> Void {
    x86_rex(ref output, wide, X86Register.None, X86Register.None, register);
    x86_emit_byte(ref output, Byte(211));
    x86_emit_byte(ref output, x86_modrm_group(group, register));
}

func x86_shift_double_imm8(ref output: X86CodeBuffer, destination: X86Register, source: X86Register, amount: Byte, left: Bool) -> Void {
    x86_rex(ref output, true, source, X86Register.None, destination);
    x86_emit_byte(ref output, Byte(15));
    let opcode: Byte = Byte(172);
    if (left) { opcode = Byte(164); }
    x86_emit_byte(ref output, opcode);
    x86_emit_byte(ref output, x86_modrm_register(source, destination));
    x86_emit_byte(ref output, amount);
}

func x86_shift_double_cl(ref output: X86CodeBuffer, destination: X86Register, source: X86Register, left: Bool) -> Void {
    x86_rex(ref output, true, source, X86Register.None, destination);
    x86_emit_byte(ref output, Byte(15));
    let opcode: Byte = Byte(173);
    if (left) { opcode = Byte(165); }
    x86_emit_byte(ref output, opcode);
    x86_emit_byte(ref output, x86_modrm_register(source, destination));
}

func x86_unary_register(ref output: X86CodeBuffer, register: X86Register, group: Int, wide: Bool) -> Void {
    x86_rex(ref output, wide, X86Register.None, X86Register.None, register);
    x86_emit_byte(ref output, Byte(247));
    x86_emit_byte(ref output, x86_modrm_group(group, register));
}

func x86_prepare_dividend(ref output: X86CodeBuffer, wide: Bool, signed: Bool) -> Void {
    if (signed) {
        if (wide) { x86_emit_byte(ref output, Byte(72)); }
        x86_emit_byte(ref output, Byte(153));
        return;
    }
    x86_xor_register_width(ref output, X86Register.RDX, X86Register.RDX, false);
}

func x86_div_register_width(ref output: X86CodeBuffer, divisor: X86Register, wide: Bool, signed: Bool) -> Void {
    x86_rex(ref output, wide, X86Register.None, X86Register.None, divisor);
    x86_emit_byte(ref output, Byte(247));
    let group: Int = 6;
    if (signed) { group = 7; }
    x86_emit_byte(ref output, x86_modrm_group(group, divisor));
}

func x86_add_eax_imm32(ref output: X86CodeBuffer, value: UInt32) -> Void {
    x86_add_register_imm32(ref output, X86Register.RAX, value);
}

func x86_add_register_imm32(ref output: X86CodeBuffer, destination: X86Register, value: UInt32) -> Void {
    x86_add_register_imm(ref output, destination, value, false);
}

func x86_add_register_imm(ref output: X86CodeBuffer, destination: X86Register, value: UInt32, wide: Bool) -> Void {
    x86_rex(ref output, wide, X86Register.None, X86Register.None, destination);
    if (value <= 127U) {
        x86_emit_byte(ref output, Byte(131));
        x86_emit_byte(ref output, x86_modrm_group(0, destination));
        x86_emit_byte(ref output, Byte(value));
        return;
    }
    x86_emit_byte(ref output, Byte(129));
    x86_emit_byte(ref output, x86_modrm_group(0, destination));
    x86_emit_u32(ref output, value);
}

func x86_sub_eax_imm32(ref output: X86CodeBuffer, value: UInt32) -> Void {
    x86_sub_register_imm32(ref output, X86Register.RAX, value);
}

func x86_sub_register_imm32(ref output: X86CodeBuffer, destination: X86Register, value: UInt32) -> Void {
    x86_sub_register_imm(ref output, destination, value, false);
}

func x86_sub_register_imm(ref output: X86CodeBuffer, destination: X86Register, value: UInt32, wide: Bool) -> Void {
    x86_rex(ref output, wide, X86Register.None, X86Register.None, destination);
    if (value <= 127U) {
        x86_emit_byte(ref output, Byte(131));
        x86_emit_byte(ref output, x86_modrm_group(5, destination));
        x86_emit_byte(ref output, Byte(value));
        return;
    }
    x86_emit_byte(ref output, Byte(129));
    x86_emit_byte(ref output, x86_modrm_group(5, destination));
    x86_emit_u32(ref output, value);
}

func x86_imul_eax_imm32(ref output: X86CodeBuffer, value: UInt32) -> Void {
    x86_imul_register_imm32(ref output, X86Register.RAX, value);
}

func x86_imul_register_imm32(ref output: X86CodeBuffer, destination: X86Register, value: UInt32) -> Void {
    x86_imul_register_imm(ref output, destination, value, false);
}

func x86_imul_register_imm(ref output: X86CodeBuffer, destination: X86Register, value: UInt32, wide: Bool) -> Void {
    x86_rex(ref output, wide, destination, X86Register.None, destination);
    if (value <= 127U) {
        x86_emit_byte(ref output, Byte(107));
        x86_emit_byte(ref output, x86_modrm_register(destination, destination));
        x86_emit_byte(ref output, Byte(value));
        return;
    }
    x86_emit_byte(ref output, Byte(105));
    x86_emit_byte(ref output, x86_modrm_register(destination, destination));
    x86_emit_u32(ref output, value);
}

func x86_cmp_eax_imm32(ref output: X86CodeBuffer, value: UInt32) -> Void {
    x86_cmp_register_imm32(ref output, X86Register.RAX, value);
}

func x86_cmp_register_imm32(ref output: X86CodeBuffer, register: X86Register, value: UInt32) -> Void {
    x86_cmp_register_imm(ref output, register, value, false);
}

func x86_cmp_register_imm(ref output: X86CodeBuffer, register: X86Register, value: UInt32, wide: Bool) -> Void {
    if (value <= 127U) {
        x86_rex(ref output, wide, X86Register.None, X86Register.None, register);
        x86_emit_byte(ref output, Byte(131));
        x86_emit_byte(ref output, x86_modrm_group(7, register));
        x86_emit_byte(ref output, Byte(value));
        return;
    }
    if (register == X86Register.RAX) {
        x86_rex(ref output, wide, X86Register.None, X86Register.None, register);
        x86_emit_byte(ref output, Byte(61));
        x86_emit_u32(ref output, value);
        return;
    }
    x86_rex(ref output, wide, X86Register.None, X86Register.None, register);
    x86_emit_byte(ref output, Byte(129));
    x86_emit_byte(ref output, x86_modrm_group(7, register));
    x86_emit_u32(ref output, value);
}

func x86_cmp_register32(ref output: X86CodeBuffer, left: X86Register, right: X86Register) -> Void {
    x86_rex(ref output, false, right, X86Register.None, left);
    x86_emit_byte(ref output, Byte(57));
    x86_emit_byte(ref output, x86_modrm_register(right, left));
}

func x86_cmp_register64(ref output: X86CodeBuffer, left: X86Register, right: X86Register) -> Void {
    x86_rex(ref output, true, right, X86Register.None, left);
    x86_emit_byte(ref output, Byte(57));
    x86_emit_byte(ref output, x86_modrm_register(right, left));
}

func x86_test_register_width(ref output: X86CodeBuffer, left: X86Register, right: X86Register, wide: Bool) -> Void {
    x86_rex(ref output, wide, right, X86Register.None, left);
    x86_emit_byte(ref output, Byte(133));
    x86_emit_byte(ref output, x86_modrm_register(right, left));
}

func x86_set_condition_register(ref output: X86CodeBuffer, destination: X86Register, opcode: X86Opcode) -> Bool {
    let code: Byte = Byte(0);
    if (opcode == X86Opcode.Je) { code = Byte(148); }
    else if (opcode == X86Opcode.Jne) { code = Byte(149); }
    else if (opcode == X86Opcode.Jl) { code = Byte(156); }
    else if (opcode == X86Opcode.Jle) { code = Byte(158); }
    else if (opcode == X86Opcode.Jg) { code = Byte(159); }
    else if (opcode == X86Opcode.Jge) { code = Byte(157); }
    else if (opcode == X86Opcode.Ja) { code = Byte(151); }
    else if (opcode == X86Opcode.Jae) { code = Byte(147); }
    else if (opcode == X86Opcode.Jb) { code = Byte(146); }
    else if (opcode == X86Opcode.Jbe) { code = Byte(150); }
    else if (opcode == X86Opcode.Jp) { code = Byte(154); }
    else if (opcode == X86Opcode.Jnp) { code = Byte(155); }
    else {
        return false;
    }

    // SETcc writes one byte. For register codes 4-7 a REX prefix changes the old
    // high-byte registers into SPL, BPL, SIL and DIL, which is what the allocator uses.
    x86_rex(ref output, false, X86Register.None, X86Register.None, destination);
    if (!x86_register_extended(destination) && x86_register_code(destination) >= 4) {
        x86_emit_byte(ref output, Byte(64));
    }
    x86_emit_byte(ref output, Byte(15));
    x86_emit_byte(ref output, code);
    x86_emit_byte(ref output, x86_modrm_group(0, destination));
    x86_extend_register(ref output, destination, destination, 1, false);
    return true;
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

func x86_call_register(ref output: X86CodeBuffer, target: X86Register) -> Bool {
    if (x86_register_code(target) < 0) {
        return false;
    }
    // near indirect calls use a 64-bit target without a REX.W prefix.
    x86_rex(ref output, false, X86Register.None, X86Register.None, target);
    x86_emit_byte(ref output, Byte(255));
    x86_emit_byte(ref output, x86_modrm_group(2, target));
    return true;
}

func x86_atomic_xadd(ref output: X86CodeBuffer, address: X86Register, value: X86Register, size: Int) -> Bool {
    if (x86_register_code(address) < 0 || x86_register_code(value) < 0 ||
        (size != 1 && size != 2 && size != 4 && size != 8)) {
        return false;
    }

    // LOCK is required for read-modify-write operations shared between cores.
    x86_emit_byte(ref output, Byte(240));
    if (size == 2) {
        x86_emit_byte(ref output, Byte(102));
    }
    x86_rex(ref output, size == 8, value, X86Register.None, address);
    if (size == 1 && !x86_register_extended(value) && !x86_register_extended(address) && x86_register_code(value) >= 4) {
        x86_emit_byte(ref output, Byte(64));
    }
    x86_emit_byte(ref output, Byte(15));
    if (size == 1) {
        x86_emit_byte(ref output, Byte(192));
    } else {
        x86_emit_byte(ref output, Byte(193));
    }
    x86_emit_byte(ref output, Byte(((x86_register_code(value) & 7) << 3) | (x86_register_code(address) & 7)));
    if ((x86_register_code(address) & 7) == 4) {
        x86_emit_byte(ref output, Byte(36));
    }
    return true;
}

func x86_atomic_exchange(ref output: X86CodeBuffer, address: X86Register, value: X86Register, size: Int) -> Bool {
    if (x86_register_code(address) < 0 || x86_register_code(value) < 0 ||
        (size != 1 && size != 2 && size != 4 && size != 8)) {
        return false;
    }

    // XCHG with a memory operand is atomic without an explicit LOCK prefix.
    if (size == 2) {
        x86_emit_byte(ref output, Byte(102));
    }
    x86_rex(ref output, size == 8, value, X86Register.None, address);
    if (size == 1 && !x86_register_extended(value) && !x86_register_extended(address) && x86_register_code(value) >= 4) {
        x86_emit_byte(ref output, Byte(64));
    }
    if (size == 1) {
        x86_emit_byte(ref output, Byte(134));
    } else {
        x86_emit_byte(ref output, Byte(135));
    }
    x86_emit_byte(ref output, Byte(((x86_register_code(value) & 7) << 3) | (x86_register_code(address) & 7)));
    if ((x86_register_code(address) & 7) == 4) {
        x86_emit_byte(ref output, Byte(36));
    }
    return true;
}

func x86_atomic_compare_exchange(ref output: X86CodeBuffer, address: X86Register, value: X86Register, size: Int) -> Bool {
    if (x86_register_code(address) < 0 || x86_register_code(value) < 0 ||
        (size != 1 && size != 2 && size != 4 && size != 8)) {
        return false;
    }

    // CMPXCHG has an implicit accumulator input, lowering is responsible for
    // placing the expected value in RAX before calling this encoder.
    x86_emit_byte(ref output, Byte(240));
    if (size == 2) {
        x86_emit_byte(ref output, Byte(102));
    }
    x86_rex(ref output, size == 8, value, X86Register.None, address);
    if (size == 1 && !x86_register_extended(value) && !x86_register_extended(address) && x86_register_code(value) >= 4) {
        x86_emit_byte(ref output, Byte(64));
    }
    x86_emit_byte(ref output, Byte(15));
    if (size == 1) {
        x86_emit_byte(ref output, Byte(176));
    } else {
        x86_emit_byte(ref output, Byte(177));
    }
    x86_emit_byte(ref output, Byte(((x86_register_code(value) & 7) << 3) | (x86_register_code(address) & 7)));
    if ((x86_register_code(address) & 7) == 4) {
        x86_emit_byte(ref output, Byte(36));
    }
    return true;
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
    else if (opcode == X86Opcode.Jp) { code = Byte(138); }
    else if (opcode == X86Opcode.Jnp) { code = Byte(139); }
    else { return -1; }

    x86_emit_byte(ref output, Byte(15));
    x86_emit_byte(ref output, code);
    let patch_offset: Int = output.bytes.length();
    x86_emit_u32(ref output, 0U);

    return patch_offset;
}

func x86_trap(ref output: X86CodeBuffer) -> Void {
    x86_emit_byte(ref output, Byte(15));
    x86_emit_byte(ref output, Byte(11));
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

func x86_touch_rsp(ref output: X86CodeBuffer) -> Void {
    // test byte ptr [rsp], 0, the read commits a guard page without changing stack data.
    x86_emit_byte(ref output, Byte(246));
    x86_emit_byte(ref output, Byte(4));
    x86_emit_byte(ref output, Byte(36));
    x86_emit_byte(ref output, Byte(0));
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
    x86_store_register_base_disp32(ref output, source, base, displacement, 4);
}

func x86_load_register32_base_disp32(ref output: X86CodeBuffer, destination: X86Register, base: X86Register, displacement: Int) -> Void {
    x86_load_register_base_disp32(ref output, destination, base, displacement, 4, false);
}

func x86_store_register_base_disp32(ref output: X86CodeBuffer, source: X86Register, base: X86Register, displacement: Int, size: Int) -> Void {
    let base_code: Int = x86_register_code(base);
    let source_code: Int = x86_register_code(source);
    if (base_code < 0 || source_code < 0 || (size != 1 && size != 2 && size != 4 && size != 8)) {
        return;
    }

    if (size == 2) {
        x86_emit_byte(ref output, Byte(102));
    }

    x86_rex(ref output, size == 8, source, X86Register.None, base);

    if (size == 1 && !x86_register_extended(source) && !x86_register_extended(base) && source_code >= 4) {
        x86_emit_byte(ref output, Byte(64));
    }
    if (size == 1) {
        x86_emit_byte(ref output, Byte(136));
    } else {
        x86_emit_byte(ref output, Byte(137));
    }

    x86_emit_byte(ref output, Byte(128 | ((source_code & 7) << 3) | (base_code & 7)));

    // an RSP/R12 base always requires a SIB byte, even when no index is present.
    if ((base_code & 7) == 4) {
        x86_emit_byte(ref output, Byte(36));
    }

    x86_emit_i32(ref output, displacement);
}

func x86_load_register_base_disp32(ref output: X86CodeBuffer, destination: X86Register, base: X86Register, displacement: Int, size: Int, signed: Bool) -> Void {
    let base_code: Int = x86_register_code(base);
    let destination_code: Int = x86_register_code(destination);
    if (base_code < 0 || destination_code < 0 || (size != 1 && size != 2 && size != 4 && size != 8)) {
        return;
    }

    if (size == 1 || size == 2) {
        x86_rex(ref output, false, destination, X86Register.None, base);
        x86_emit_byte(ref output, Byte(15));
        if (size == 1) {
            if signed {
                x86_emit_byte(ref output, Byte(190));
            } else {
                x86_emit_byte(ref output, Byte(182));
            }
        } else {
            if signed {
                x86_emit_byte(ref output, Byte(191));
            } else {
                x86_emit_byte(ref output, Byte(183));
            }
        }
    } else {
        x86_rex(ref output, size == 8, destination, X86Register.None, base);
        x86_emit_byte(ref output, Byte(139));
    }

    x86_emit_byte(ref output, Byte(128 | ((destination_code & 7) << 3) | (base_code & 7)));

    if ((base_code & 7) == 4) {
        x86_emit_byte(ref output, Byte(36));
    }

    x86_emit_i32(ref output, displacement);
}

func x86_memory_indexed(ref output: X86CodeBuffer, register: X86Register, base: X86Register, index: X86Register, displacement: Int, size: Int, store: Bool) -> Bool {
    let reg_code = x86_register_code(register);
    let base_code = x86_register_code(base);
    let index_code = x86_register_code(index);
    if (reg_code < 0 || base_code < 0 || index_code < 0 || index == X86Register.RSP ||
        (size != 1 && size != 2 && size != 4 && size != 8)) {
        return false;
    }
    if (store && size == 2) {
        x86_emit_byte(ref output, Byte(102));
    }
    x86_rex(ref output, size == 8, register, index, base);
    if (store && size == 1 && reg_code >= 4 && !x86_register_extended(register) &&
        !x86_register_extended(index) && !x86_register_extended(base)) {
        x86_emit_byte(ref output, Byte(64));
    }
    if (store) {
        if (size == 1) {
            x86_emit_byte(ref output, Byte(136));
        } else {
            x86_emit_byte(ref output, Byte(137));
        }
    } else if (size == 1 || size == 2) {
        x86_emit_byte(ref output, Byte(15));
        if (size == 1) {
            x86_emit_byte(ref output, Byte(182));
        } else {
            x86_emit_byte(ref output, Byte(183));
        }
    } else {
        x86_emit_byte(ref output, Byte(139));
    }
    x86_emit_byte(ref output, Byte(132 | ((reg_code & 7) << 3)));
    x86_emit_byte(ref output, Byte(((index_code & 7) << 3) | (base_code & 7)));
    x86_emit_i32(ref output, displacement);
    return true;
}

func x86_frame_enter(ref output: X86CodeBuffer, size: Int) -> Void {
    x86_push_rbp(ref output);
    x86_mov_rbp_rsp(ref output);

    // Windows grows the stack through guard pages. Touch every 4 KiB while moving
    // RSP so a large frame cannot jump over the guard page.
    let remaining: Int = size;
    while (remaining > 4096) {
        x86_sub_rsp_imm32(ref output, 4096U);
        x86_touch_rsp(ref output);
        remaining -= 4096;
    }
    if (remaining > 0) {
        x86_sub_rsp_imm32(ref output, UInt32(remaining));
    }
}

func x86_frame_leave(ref output: X86CodeBuffer) -> Void {
    x86_mov_rsp_rbp(ref output);
    x86_pop_rbp(ref output);
}

func x86_return(ref output: X86CodeBuffer) -> Void {
    x86_emit_byte(ref output, Byte(195));
}
