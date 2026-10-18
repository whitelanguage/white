// src/compiler/machine/x86_64/memory.wl
import * from "model.wl"
import * from "encoder.wl"
import x86_is_sysv_abi from "abi.wl"
import * from "sse.wl"


func x86_is_memop(name: String) -> Bool {
// WIR uses these names as ordinary calls. Keeping the three helpers here means
// freestanding programs do not gain a CRT dependency just because a copy was lowered.
    return name == "memcpy" || name == "memmove" || name == "memset";
}

func x86_emit_memop(ref output: X86CodeBuffer, name: String) -> Bool {
// Win64 passes destination, source/value and count in RCX, RDX and R8.
// These are leaf functions, R9 and R10 are volatile and may be used as scratch.
    if (!x86_is_memop(name)) { return false; }

    // The body below uses the Win64 register names to keep the byte loop small.
    // Shuffle the three SysV arguments once when this helper is emitted for ELF.
    if (x86_is_sysv_abi()) {
        x86_mov_register64(ref output, X86Register.R10, X86Register.RDX);
        x86_mov_register64(ref output, X86Register.RCX, X86Register.RDI);
        x86_mov_register64(ref output, X86Register.RDX, X86Register.RSI);
        x86_mov_register64(ref output, X86Register.R8, X86Register.R10);
    }

    x86_mov_register64(ref output, X86Register.RAX, X86Register.RCX);
    x86_mov_register_imm32(ref output, X86Register.R9, 0U);
    x86_cmp_register64(ref output, X86Register.R8, X86Register.R9);
    let empty: Int = x86_jump_if_rel32(ref output, X86Opcode.Je);

    if (name == "memmove") {
        // a destination below the source cannot overwrite unread bytes. The other
        // ordering is copied from the end, including destination == source.
        x86_cmp_register64(ref output, X86Register.RCX, X86Register.RDX);
        let forward: Int = x86_jump_if_rel32(ref output, X86Opcode.Jbe);
        let backward: Int = output.bytes.length();
        x86_lea(ref output, X86Register.R8, X86Register.R8, X86Register.None, 1, -1);
        if (!x86_memory_indexed(ref output, X86Register.R10, X86Register.RDX, X86Register.R8, 0, 1, false)) {
            return false;
        }

        if (!x86_memory_indexed(ref output, X86Register.R10, X86Register.RCX, X86Register.R8, 0, 1, true)) {
            return false;
        }
        x86_cmp_register64(ref output, X86Register.R8, X86Register.R9);
        let repeat: Int = x86_jump_if_rel32(ref output, X86Opcode.Jne);

        if (!x86_patch_i32(ref output, repeat, backward - repeat - 4)) { return false; }
        x86_return(ref output);
        if (!x86_patch_i32(ref output, forward, output.bytes.length() - forward - 4)) { return false; }
    }

    x86_mov_register_imm32(ref output, X86Register.R9, 0U);
    if (name == "memset") {
        x86_mov_register32(ref output, X86Register.R10, X86Register.RDX);
    }

    let forward: Int = output.bytes.length();

    if (name != "memset" && !x86_memory_indexed(ref output, X86Register.R10, X86Register.RDX, X86Register.R9, 0, 1, false)) {
        return false;
    }

    if (!x86_memory_indexed(ref output, X86Register.R10, X86Register.RCX, X86Register.R9, 0, 1, true)) {
        return false;
    }
    x86_lea(ref output, X86Register.R9, X86Register.R9, X86Register.None, 1, 1);
    x86_cmp_register64(ref output, X86Register.R9, X86Register.R8);
    let repeat: Int = x86_jump_if_rel32(ref output, X86Opcode.Jb);

    if (!x86_patch_i32(ref output, repeat, forward - repeat - 4)) { return false; }
    if (!x86_patch_i32(ref output, empty, output.bytes.length() - empty - 4)) { return false; }
    x86_return(ref output);

    return true;
}

func x86_transfer_memory(
    ref output: X86CodeBuffer,
    destination: X86Register,
    destination_offset: Int,
    source: X86Register,
    source_offset: Int,
    size: Int,
    temporary: X86Register,
    zero: Bool
) -> Bool {
// aggregate homes never alias their destination, this is copy, not memmove.
    if (size < 0 || x86_register_code(destination) < 0 || x86_register_code(temporary) < 0 ||
        temporary == destination || destination == X86Register.RCX || temporary == X86Register.RCX ||
        temporary == X86Register.RSP || temporary == X86Register.RBP ||
        destination_offset > 2147483647 - size) {
        return false;
    }

    if (!zero && (x86_register_code(source) < 0 || source == temporary || source == X86Register.RCX ||
        source_offset > 2147483647 - size)) {
        return false;
    }

    if (size == 0) { return true; }
    if zero {
        x86_mov_register_imm32(ref output, temporary, 0U);
    }

    let position: Int = 0;

    if (size > 64) {
        // unrolling a large aggregate makes both the object and instruction cache worse.
        // RCX is kept out of the allocator for this small counted loop.
        let bulk: Int = (size / 8) * 8;
        x86_mov_register_imm32(ref output, X86Register.RCX, 0U);
        let loop: Int = output.bytes.length();

        if (!zero && !x86_memory_indexed(ref output, temporary, source, X86Register.RCX, source_offset, 8, false)) {
            return false;
        }

        if (!x86_memory_indexed(ref output, temporary, destination, X86Register.RCX, destination_offset, 8, true)) {
            return false;
        }
        x86_add_register_imm32(ref output, X86Register.RCX, 8U);
        x86_cmp_register_imm32(ref output, X86Register.RCX, UInt32(bulk));
        let repeat: Int = x86_jump_if_rel32(ref output, X86Opcode.Jb);

        if (!x86_patch_i32(ref output, repeat, loop - (repeat + 4))) { return false; }
        position = bulk;
    }

    while (position < size) {
        // finish with the widest legal load/store, so 1..7 trailing bytes need at
        // most three pairs of instructions.
        let width: Int = 8;

        while (width > size - position) {
            width /= 2;
        }

        if (!zero) {
            x86_load_register_base_disp32(ref output, temporary, source, source_offset + position, width, false);
        }
        x86_store_register_base_disp32(ref output, temporary, destination, destination_offset + position, width);
        position += width;
    }

    return true;
}

func x86_copy_memory(
    ref output: X86CodeBuffer,
    destination: X86Register,
    destination_offset: Int,
    source: X86Register,
    source_offset: Int,
    size: Int,
    temporary: X86Register
) -> Bool {
    return x86_transfer_memory(ref output, destination, destination_offset, source, source_offset, size, temporary, false);
}

func x86_zero_memory(ref output: X86CodeBuffer, destination: X86Register, destination_offset: Int, size: Int, temporary: X86Register) -> Bool {
    return x86_transfer_memory(ref output, destination, destination_offset, X86Register.None, 0, size, temporary, true);
}

func x86_move_scalar(ref output: X86CodeBuffer, destination: X86Register, source: X86Register, size: Int) -> Bool {
    if (x86_is_xmm(destination) && x86_is_xmm(source)) {
        return x86_sse_register(ref output, 16, destination, source, size);
    }
    if (x86_is_xmm(destination)) {
        return x86_sse_bits(ref output, destination, source, size, true);
    }
    if (x86_is_xmm(source)) {
        return x86_sse_bits(ref output, source, destination, size, false);
    }
    if (size == 8) {
        x86_mov_register64(ref output, destination, source);
        return true;
    }
    if (size == 1 || size == 2 || size == 4) {
        x86_mov_register32(ref output, destination, source);
        return true;
    }

    return false;
}

func x86_normalize_scalar(ref output: X86CodeBuffer, register: X86Register, size: Int, signed: Bool) -> Void {
    if (x86_is_xmm(register)) { return; }
    if (size == 1 || size == 2) {
        x86_extend_register(ref output, register, register, size, signed);
    }
}

func x86_load_scalar(ref output: X86CodeBuffer, destination: X86Register, base: X86Register, displacement: Int, size: Int, signed: Bool) -> Bool {
    if (x86_is_xmm(destination)) {
        return x86_sse_memory(ref output, 16, destination, base, displacement, size);
    }
    if (size != 1 && size != 2 && size != 4 && size != 8) { return false; }
    x86_load_register_base_disp32(ref output, destination, base, displacement, size, signed);
    return true;
}

func x86_store_scalar(ref output: X86CodeBuffer, source: X86Register, base: X86Register, displacement: Int, size: Int) -> Bool {
    if (x86_is_xmm(source)) {
        return x86_sse_memory(ref output, 17, source, base, displacement, size);
    }
    if (size != 1 && size != 2 && size != 4 && size != 8) { return false; }
    x86_store_register_base_disp32(ref output, source, base, displacement, size);
    return true;
}
