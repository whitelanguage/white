// compiler/machine/x86_64/memory.wl
import * from "model.wl"
import * from "encoder.wl"

func x86_transfer_memory(ref output: X86CodeBuffer, destination: X86Register, destination_offset: Int, source: X86Register, source_offset: Int, size: Int, temporary: X86Register, zero: Bool) -> Bool {
    // aggregate homes never alias their destination; this is copy, not memmove
    if (size < 0 || x86_register_code(destination) < 0 || x86_register_code(temporary) < 0 ||
        temporary == destination || destination == X86Register.RCX || temporary == X86Register.RCX ||
        temporary == X86Register.RSP || temporary == X86Register.RBP ||
        destination_offset > 2147483647 - size) { return false; }
    if (!zero && (x86_register_code(source) < 0 || source == temporary || source == X86Register.RCX ||
        source_offset > 2147483647 - size)) { return false; }
    if (size == 0) { return true; }
    if (zero) { x86_mov_register_imm32(ref output, temporary, 0U); }
    let position: Int = 0;
    if (size > 64) {
        // keep large copies bounded in code size; RCX is reserved by the lowering
        let bulk: Int = (size / 8) * 8;
        x86_mov_register_imm32(ref output, X86Register.RCX, 0U);
        let loop: Int = output.bytes.length();
        if (!zero && !x86_memory_indexed(ref output, temporary, source, X86Register.RCX, source_offset, 8, false)) { return false; }
        if (!x86_memory_indexed(ref output, temporary, destination, X86Register.RCX, destination_offset, 8, true)) { return false; }
        x86_add_register_imm32(ref output, X86Register.RCX, 8U);
        x86_cmp_register_imm32(ref output, X86Register.RCX, UInt32(bulk));
        let repeat: Int = x86_jump_if_rel32(ref output, X86Opcode.Jb);
        if (!x86_patch_i32(ref output, repeat, loop - (repeat + 4))) { return false; }
        position = bulk;
    }
    while (position < size) {
        let width: Int = 8;
        while (width > size - position) { width /= 2; }
        if (!zero) { x86_load_register_base_disp32(ref output, temporary, source, source_offset + position, width, false); }
        x86_store_register_base_disp32(ref output, temporary, destination, destination_offset + position, width);
        position += width;
    }
    return true;
}

func x86_copy_memory(ref output: X86CodeBuffer, destination: X86Register, destination_offset: Int, source: X86Register, source_offset: Int, size: Int, temporary: X86Register) -> Bool {
    return x86_transfer_memory(ref output, destination, destination_offset, source, source_offset, size, temporary, false);
}

func x86_zero_memory(ref output: X86CodeBuffer, destination: X86Register, destination_offset: Int, size: Int, temporary: X86Register) -> Bool {
    return x86_transfer_memory(ref output, destination, destination_offset, X86Register.None, 0, size, temporary, true);
}
