// compiler/machine/x86_64/memory.wl
import * from "model.wl"
import * from "encoder.wl"

func x86_is_memop(name: String) -> Bool {
    return name == "memcpy" || name == "memmove" || name == "memset";
}

func x86_emit_memop(ref output: X86CodeBuffer, name: String) -> Bool {
    // Win64 leaf helpers: RCX=destination, RDX=source/value, R8=count, RAX=result
    if (!x86_is_memop(name)) { return false; }
    x86_mov_register64(ref output, X86Register.RAX, X86Register.RCX);
    x86_mov_register_imm32(ref output, X86Register.R9, 0U);
    x86_cmp_register64(ref output, X86Register.R8, X86Register.R9);
    let empty: Int = x86_jump_if_rel32(ref output, X86Opcode.Je);
    if (name == "memmove") {
        x86_cmp_register64(ref output, X86Register.RCX, X86Register.RDX);
        let forward: Int = x86_jump_if_rel32(ref output, X86Opcode.Jbe);
        let backward: Int = output.bytes.length();
        x86_lea(ref output, X86Register.R8, X86Register.R8, X86Register.None, 1, -1);
        if (!x86_memory_indexed(ref output, X86Register.R10, X86Register.RDX, X86Register.R8, 0, 1, false)) { return false; }
        if (!x86_memory_indexed(ref output, X86Register.R10, X86Register.RCX, X86Register.R8, 0, 1, true)) { return false; }
        x86_cmp_register64(ref output, X86Register.R8, X86Register.R9);
        let repeat: Int = x86_jump_if_rel32(ref output, X86Opcode.Jne);
        if (!x86_patch_i32(ref output, repeat, backward - repeat - 4)) { return false; }
        x86_return(ref output);
        if (!x86_patch_i32(ref output, forward, output.bytes.length() - forward - 4)) { return false; }
    }
    x86_mov_register_imm32(ref output, X86Register.R9, 0U);
    if (name == "memset") { x86_mov_register32(ref output, X86Register.R10, X86Register.RDX); }
    let forward: Int = output.bytes.length();
    if (name != "memset" && !x86_memory_indexed(ref output, X86Register.R10, X86Register.RDX, X86Register.R9, 0, 1, false)) { return false; }
    if (!x86_memory_indexed(ref output, X86Register.R10, X86Register.RCX, X86Register.R9, 0, 1, true)) { return false; }
    x86_lea(ref output, X86Register.R9, X86Register.R9, X86Register.None, 1, 1);
    x86_cmp_register64(ref output, X86Register.R9, X86Register.R8);
    let repeat: Int = x86_jump_if_rel32(ref output, X86Opcode.Jb);
    if (!x86_patch_i32(ref output, repeat, forward - repeat - 4)) { return false; }
    if (!x86_patch_i32(ref output, empty, output.bytes.length() - empty - 4)) { return false; }
    x86_return(ref output);
    return true;
}

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
