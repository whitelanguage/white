// Test: FRAME_BOUNDS
// File: tests/machine/test_frame_bounds.wl
// Focus: Rejecting oversized stack layouts before alignment or spill offsets overflow.

import * from "../../src/compiler/wir/model.wl"
import * from "../../src/compiler/wir/builder.wl"
import x86_lower_function from "../../src/compiler/machine/x86_64/lowering.wl"
import a64_lower_function from "../../src/compiler/machine/aarch64/lowering.wl"
import X86StackSlot, x86_spill_locations, x86_stack_frame_size from "../../src/compiler/machine/x86_64/stack.wl"


func oversized(ref program: WirModule) -> WirFuncID {
    let byte = wir_unsigned_int_type(ref program, 8);
    let word = wir_unsigned_int_type(ref program, 64);
    let array = wir_array_type(ref program, byte, UIntSize(2147483640));
    let function = wir_add_function(ref program, "large", [], program.void_type, false, WirLinkage.Internal, WirABI.White);
    let entry = wir_add_block(ref program, function, "entry", []);
    wir_stack_alloc(ref program, entry, array, "first", no_wir_location());
    wir_stack_alloc(ref program, entry, word, "second", no_wir_location());
    wir_return(ref program, entry, NO_WIR_VALUE, no_wir_location());
    return function;
}

func main() -> Int {
    // only describe the large slots, no executable frame or allocation is created
    let slots = [X86StackSlot(value=WirValueID(1U), offset=2147483640, size=8)];
    if (x86_spill_locations(slots, [], 1).length() != 0 || x86_stack_frame_size(slots, [], []) != -1) {
        print("FAIL: stack layout overflow");
        return 1;
    }

    let x86 = new_wir_module("x86_64-pc-windows-msvc", 64);
    let x86_function = oversized(ref x86);
    let x86_result = x86_lower_function(ref x86, x86_function);
    if (x86_result.errors.length() == 0) {
        print("FAIL: oversized x86 frame");
        return 1;
    }

    let arm = new_wir_module("aarch64-unknown-linux-gnu", 64);
    let arm_function = oversized(ref arm);
    let arm_result = a64_lower_function(ref arm, arm_function);
    if (arm_result.errors.length() == 0) {
        print("FAIL: oversized AArch64 frame");
        return 1;
    }

    print("PASS: oversized frame bounds");
    return 0;
}
