// Test: PATCH_BOUNDS
// File: tests/machine/test_patch_bounds.wl
// Focus: Rejecting invalid instruction patch offsets without overflowing the range check.

import * from "../../src/compiler/machine/x86_64/encoder.wl"
import * from "../../src/compiler/machine/aarch64/encoder.wl"
import A64Condition from "../../src/compiler/machine/aarch64/model.wl"


func main() -> Int {
    let x86 = x86_new_code_buffer();
    x86_emit_u32(ref x86, 0U);
    let arm = a64_new_code_buffer();
    a64_emit_u32(ref arm, 0U);

    if (x86_patch_i32(ref x86, 2147483647, 1) || a64_patch_u32(ref arm, 2147483644, 1U)) {
        print("FAIL: patch offset overflow");
        return 1;
    }
    if (x86_patch_i32(ref x86, -1, 1) || a64_patch_u32(ref arm, -4, 1U) ||
        x86_patch_i32(ref x86, 1, 1) || a64_patch_u32(ref arm, 1, 1U)) {
        print("FAIL: patch outside instruction buffer");
        return 1;
    }
    if (a64_patch_branch(ref arm, 2147483644, 0, A64Condition.Equal, false)) {
        print("FAIL: branch patch offset overflow");
        return 1;
    }
    if (!x86_patch_i32(ref x86, 0, 42) || !a64_patch_u32(ref arm, 0, 42U) ||
        x86.bytes[0] != Byte(42) || arm.bytes[0] != Byte(42)) {
        print("FAIL: valid instruction patch");
        return 1;
    }

    a64_emit_u32(ref arm, 0U);
    if (a64_patch_branch(ref arm, 4, -2147483647 - 1, A64Condition.Equal, false)) {
        print("FAIL: branch displacement overflow");
        return 1;
    }

    print("PASS: instruction patch bounds");
    return 0;
}
