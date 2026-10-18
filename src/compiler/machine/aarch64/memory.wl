// src/compiler/machine/aarch64/memory.wl
import * from "model.wl"
import * from "encoder.wl"
import a64_load_float, a64_store_float from "fp.wl"


func a64_stack_address(ref output: A64CodeBuffer, destination: A64Register, offset: Int) -> Bool {
    return a64_offset_address(ref output, destination, A64Register.SP, offset);
}

func a64_offset_address(ref output: A64CodeBuffer, destination: A64Register, base: A64Register, offset: Int) -> Bool {
    // each ADD carries at most 12 bits, chain them when a frame offset is larger.
    if (offset < 0 || destination == A64Register.None || destination == A64Register.SP ||
        base == A64Register.None || base == A64Register.ZR) {
        return false;
    }

    let remaining: Int = offset;
    let current: A64Register = base;
    if (remaining == 0) {
        return a64_add_immediate(ref output, destination, current, 0, true);
    }

    while (remaining != 0) {
        let amount: Int = remaining;
        if (amount > 4095) { amount = 4095; }
        if (!a64_add_immediate(ref output, destination, current, amount, true)) {
            return false;
        }
        remaining -= amount;
        current = destination;
    }

    return true;
}

func a64_load_integer_at(ref output: A64CodeBuffer, destination: A64Register, base: A64Register, offset: Int, width: Int) -> Bool {
    if (a64_load_integer(ref output, destination, base, offset, width)) {
        return true;
    }
    return a64_offset_address(ref output, A64Register.X16, base, offset) &&
           a64_load_integer(ref output, destination, A64Register.X16, 0, width);
}

func a64_store_integer_at(ref output: A64CodeBuffer, source: A64Register, base: A64Register, offset: Int, width: Int) -> Bool {
    if (a64_store_integer(ref output, source, base, offset, width)) {
        return true;
    }
    return a64_offset_address(ref output, A64Register.X16, base, offset) &&
           a64_store_integer(ref output, source, A64Register.X16, 0, width);
}

func a64_load_float_at(ref output: A64CodeBuffer, destination: A64Register, base: A64Register, offset: Int, double: Bool) -> Bool {
    if (a64_load_float(ref output, destination, base, offset, double)) {
        return true;
    }
    return a64_offset_address(ref output, A64Register.X16, base, offset) &&
           a64_load_float(ref output, destination, A64Register.X16, 0, double);
}

func a64_store_float_at(ref output: A64CodeBuffer, source: A64Register, base: A64Register, offset: Int, double: Bool) -> Bool {
    if (a64_store_float(ref output, source, base, offset, double)) {
        return true;
    }
    return a64_offset_address(ref output, A64Register.X16, base, offset) &&
           a64_store_float(ref output, source, A64Register.X16, 0, double);
}

func a64_copy_chunk(source_offset: Int, destination_offset: Int, remaining: Int) -> Int {
    // both addresses need the same alignment before using a wider transfer.
    if (remaining >= 8 && source_offset % 8 == 0 && destination_offset % 8 == 0) { return 64; }
    if (remaining >= 4 && source_offset % 4 == 0 && destination_offset % 4 == 0) { return 32; }
    if (remaining >= 2 && source_offset % 2 == 0 && destination_offset % 2 == 0) { return 16; }
    return 8;
}

func a64_zero_memory(ref output: A64CodeBuffer, base: A64Register, offset: Int, size: Int) -> Bool {
    let written: Int = 0;
    while (written < size) {
        let width: Int = a64_copy_chunk(offset + written, offset + written, size - written);
        if (!a64_store_integer_at(ref output, A64Register.ZR, base, offset + written, width)) {
            return false;
        }
        written += width / 8;
    }

    return true;
}

func a64_copy_memory(
    ref output: A64CodeBuffer,
    destination_base: A64Register,
    destination_offset: Int,
    source_base: A64Register,
    source_offset: Int,
    size: Int,
    temporary: A64Register
) -> Bool {
    let copied: Int = 0;
    while (copied < size) {
        let width: Int = a64_copy_chunk(source_offset + copied, destination_offset + copied, size - copied);
        let loaded: Bool = a64_load_integer(ref output, temporary, source_base, source_offset + copied, width);
        if (!loaded) {
            loaded = a64_offset_address(ref output, A64Register.X16, source_base, source_offset + copied) &&
                     a64_load_integer(ref output, temporary, A64Register.X16, 0, width);
        }

        let stored: Bool = a64_store_integer(ref output, temporary, destination_base, destination_offset + copied, width);
        if (!stored) {
            stored = a64_offset_address(ref output, A64Register.X17, destination_base, destination_offset + copied) &&
                     a64_store_integer(ref output, temporary, A64Register.X17, 0, width);
        }
        if (!loaded || !stored) {
            return false;
        }
        copied += width / 8;
    }

    return true;
}
