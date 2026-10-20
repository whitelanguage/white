// Test: NATIVE_LAYOUT
// File: tests/machine/test_layout.wl
// Focus: Both native module entry points reject mismatched layout metadata before emission.

import * from "../../src/compiler/wir/model.wl"
import new_wir_module from "../../src/compiler/wir/builder.wl"
import x86_lower_module from "../../src/compiler/machine/x86_64/module.wl"
import a64_lower_module from "../../src/compiler/machine/aarch64/module.wl"


func rejected(ref program: WirModule, arm: Bool) -> Bool {
    if arm { return a64_lower_module(ref program).errors.length() != 0; }
    return x86_lower_module(ref program).errors.length() != 0;
}

func check(target: String, arm: Bool) -> Bool {
    let program = new_wir_module(target, 64);
    if (rejected(ref program, arm)) { return false; }
    let layout = program.data_layout;
    program.data_layout.valid = false;
    if (!rejected(ref program, arm)) { return false; }
    program.data_layout = layout;
    program.data_layout.little_endian = false;
    if (!rejected(ref program, arm)) { return false; }
    program.data_layout = layout;
    program.data_layout.pointer_alignment = 4;
    if (!rejected(ref program, arm)) { return false; }
    program.data_layout = layout;
    program.data_layout.i128_alignment = 8;
    if (!rejected(ref program, arm)) { return false; }
    program.data_layout = layout;
    program.data_layout.stack_alignment = 4;
    if (!rejected(ref program, arm)) { return false; }
    program.data_layout = layout;
    program.pointer_bits = 32;
    return rejected(ref program, arm);
}

func main() -> Int {
    if (!check("x86_64-pc-windows-msvc", false) || !check("x86_64-unknown-linux-gnu", false) ||
        !check("aarch64-unknown-linux-gnu", true)) {
        print("FAIL: native layout validation");
        return 1;
    }
    print("PASS: native layout validation");
    return 0;
}
