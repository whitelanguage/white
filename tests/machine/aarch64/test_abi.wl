// Test: AARCH64_AAPCS64
// File: tests/machine/aarch64/test_abi.wl
// Focus: Keep the base AAPCS64 argument, result and stack locations stable.

import * from "../../../src/compiler/machine/aarch64/model.wl"
import * from "../../../src/compiler/machine/aarch64/abi.wl"


func main() -> Int {
    if (a64_argument_register(0, false) != A64Register.X0 ||
        a64_argument_register(7, false) != A64Register.X7 ||
        a64_argument_register(0, true) != A64Register.V0 ||
        a64_argument_register(7, true) != A64Register.V7 ||
        a64_argument_register(8, false) != A64Register.None) {
        print("FAIL: AAPCS64 argument registers are incorrect");
        return 1;
    }

    if (a64_result_register(false) != A64Register.X0 ||
        a64_result_register(true) != A64Register.V0 ||
        a64_indirect_result_register() != A64Register.X8) {
        print("FAIL: AAPCS64 result registers are incorrect");
        return 1;
    }

    if (a64_pair_argument_index(0) != 0 || a64_pair_argument_index(1) != 2 ||
        a64_pair_argument_index(5) != 6 || a64_pair_argument_index(7) != -1) {
        print("FAIL: AAPCS64 128-bit register pairs are incorrect");
        return 1;
    }

    if (a64_stack_argument_offset(7) != -1 || a64_stack_argument_offset(8) != 0 ||
        a64_stack_argument_offset(10) != 16 || a64_call_frame(8) != 0 ||
        a64_call_frame(9) != 16 || a64_call_frame(11) != 32) {
        print("FAIL: AAPCS64 stack argument layout is incorrect");
        return 1;
    }

    print("PASS: AAPCS64 base calling convention");
    return 0;
}
