// Test: X86_64_MEMORY_COPY
// File: tests/machine/x86_64/test_memcopy.wl
// Focus: Bounded copy code and indexed memory operands, including low-byte registers.

import * from "../../../src/compiler/machine/x86_64/model.wl"
import * from "../../../src/compiler/machine/x86_64/encoder.wl"
import * from "../../../src/compiler/machine/x86_64/memory.wl"

func main() -> Int {
    let output: X86CodeBuffer = x86_new_code_buffer();
    if (!x86_copy_memory(ref output, X86Register.R10, 0, X86Register.R11, 0, 1048576, X86Register.RAX) || output.bytes.length() > 64) {
        print("FAIL: large copy expanded with object size");
        return 1;
    }
    output = x86_new_code_buffer();
    if (!x86_zero_memory(ref output, X86Register.RBP, -1048576, 1048576, X86Register.RAX) || output.bytes.length() > 64) {
        print("FAIL: large zero initialization expanded with object size");
        return 1;
    }
    output = x86_new_code_buffer();
    if (!x86_memory_indexed(ref output, X86Register.RSI, X86Register.RBP, X86Register.RCX, 0, 1, true) ||
        output.bytes.length() != 8 || output.bytes[0] != Byte(64) || output.bytes[1] != Byte(136) || output.bytes[2] != Byte(180) || output.bytes[3] != Byte(13)) {
        print("FAIL: indexed byte store encoded AH instead of SIL");
        return 1;
    }
    output = x86_new_code_buffer();
    if (!x86_memory_indexed(ref output, X86Register.R11, X86Register.R12, X86Register.R13, 0, 8, false) ||
        output.bytes.length() != 8 || output.bytes[0] != Byte(79) || output.bytes[2] != Byte(156) || output.bytes[3] != Byte(44)) {
        print("FAIL: indexed load lost an extended register bit");
        return 1;
    }
    output = x86_new_code_buffer();
    if (x86_copy_memory(ref output, X86Register.R10, 0, X86Register.R11, 0, -1, X86Register.RAX) ||
        x86_copy_memory(ref output, X86Register.R10, 2147483647, X86Register.R11, 0, 8, X86Register.RAX) ||
        x86_copy_memory(ref output, X86Register.R10, 0, X86Register.R11, 0, 8, X86Register.R11) ||
        x86_memory_indexed(ref output, X86Register.RAX, X86Register.RBP, X86Register.RSP, 0, 8, false) || output.bytes.length() != 0) {
        print("FAIL: memory encoder accepted invalid operands");
        return 1;
    }
    print("PASS: bounded memory copy encoding");
    return 0;
}
