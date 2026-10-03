// Test: X86_64_SHORT_IMMEDIATES
// File: tests/machine/x86_64/test_immediates.wl
// Focus: Use sign-extended byte immediates when the value fits without changing it.

import * from "../../../src/compiler/machine/x86_64/model.wl"
import * from "../../../src/compiler/machine/x86_64/encoder.wl"

func main() -> Int {
    let output = x86_new_code_buffer();
    x86_add_register_imm32(ref output, X86Register.R10, 127U);
    x86_sub_register_imm32(ref output, X86Register.RAX, 128U);
    x86_imul_register_imm32(ref output, X86Register.R11, 8U);
    x86_cmp_register_imm32(ref output, X86Register.RAX, 1U);

    if (output.bytes.length() != 17 ||
        output.bytes[0] != Byte(65) || output.bytes[1] != Byte(131) || output.bytes[2] != Byte(194) || output.bytes[3] != Byte(127) ||
        output.bytes[4] != Byte(129) || output.bytes[5] != Byte(232) || output.bytes[6] != Byte(128) ||
        output.bytes[10] != Byte(69) || output.bytes[11] != Byte(107) || output.bytes[12] != Byte(219) || output.bytes[13] != Byte(8) ||
        output.bytes[14] != Byte(131) || output.bytes[15] != Byte(248) || output.bytes[16] != Byte(1)) {
        print("FAIL: x86_64 immediate width selection");
        return 1;
    }

    output = x86_new_code_buffer();
    x86_add_register_imm(ref output, X86Register.R10, 127U, true);
    x86_sub_register_imm(ref output, X86Register.RAX, 128U, true);
    x86_imul_register_imm(ref output, X86Register.R11, 8U, true);
    x86_cmp_register_imm(ref output, X86Register.RAX, 1U, true);
    x86_bitwise_register_imm(ref output, X86Register.R10, 63U, 4, true);
    if (output.bytes.length() != 23 ||
        output.bytes[0] != Byte(73) || output.bytes[1] != Byte(131) || output.bytes[2] != Byte(194) || output.bytes[3] != Byte(127) ||
        output.bytes[4] != Byte(72) || output.bytes[5] != Byte(129) || output.bytes[6] != Byte(232) || output.bytes[7] != Byte(128) ||
        output.bytes[11] != Byte(77) || output.bytes[12] != Byte(107) || output.bytes[13] != Byte(219) || output.bytes[14] != Byte(8) ||
        output.bytes[15] != Byte(72) || output.bytes[16] != Byte(131) || output.bytes[17] != Byte(248) || output.bytes[18] != Byte(1) ||
        output.bytes[19] != Byte(73) || output.bytes[20] != Byte(131) || output.bytes[21] != Byte(226) || output.bytes[22] != Byte(63)) {
        print("FAIL: x86_64 wide immediate width selection");
        return 1;
    }

    print("PASS: x86_64 short immediate encoding");
    return 0;
}
