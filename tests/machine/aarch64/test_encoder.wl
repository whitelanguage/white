// Test: AARCH64_ENCODER
// File: tests/machine/aarch64/test_encoder.wl
// Focus: Encode the fixed-width integer, move, branch and return instructions used by initial lowering.

import * from "../../../src/compiler/machine/aarch64/model.wl"
import * from "../../../src/compiler/machine/aarch64/encoder.wl"


func read_u32(bytes: Vector(Byte), offset: Int) -> UInt32 {
    return UInt32(bytes[offset]) |
        (UInt32(bytes[offset + 1]) << 8U) |
        (UInt32(bytes[offset + 2]) << 16U) |
        (UInt32(bytes[offset + 3]) << 24U);
}

func main() -> Int {
    let code: A64CodeBuffer = a64_new_code_buffer();

    if (!a64_mov_wide(ref code, A64Register.X0, 42U, 0, false, true) ||
        !a64_mov_wide(ref code, A64Register.X0, 1U, 16, true, true) ||
        !a64_add_register(ref code, A64Register.X0, A64Register.X0, A64Register.X1, true) ||
        !a64_sub_immediate(ref code, A64Register.SP, A64Register.SP, 16, true) ||
        !a64_add_immediate(ref code, A64Register.SP, A64Register.SP, 16, true) ||
        !a64_branch(ref code, -4, false) ||
        !a64_return(ref code, A64Register.X30)) {
        print("FAIL: a valid AArch64 instruction was rejected");
        return 1;
    }

    let expected: Vector(UInt32) = [
        0xD2800540U,
        0xF2A00020U,
        0x8B010000U,
        0xD10043FFU,
        0x910043FFU,
        0x17FFFFFFU,
        0xD65F03C0U
    ];
    let i: Int = 0;

    while (i < expected.length()) {
        if (read_u32(code.bytes, i * 4) != expected[i]) {
            print("FAIL: unexpected AArch64 instruction word at ", i);
            return 1;
        }
        i++;
    }

    if (a64_add_immediate(ref code, A64Register.X0, A64Register.X1, 4096, true) ||
        a64_branch(ref code, 2, false) ||
        a64_mov_register(ref code, A64Register.SP, A64Register.X0, true)) {
        print("FAIL: an invalid AArch64 encoding was accepted");
        return 1;
    }

    if (!a64_branch_symbol(ref code, "puts", true) || code.relocations.length() != 1 ||
        code.relocations[0].kind != A64RelocationKind.Call26 || code.relocations[0].offset != UInt32(expected.length() * 4)) {
        print("FAIL: call relocation was not recorded");
        return 1;
    }

    print("PASS: AArch64 instruction encoding");
    return 0;
}
