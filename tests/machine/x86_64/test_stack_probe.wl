// Test: X86_64_STACK_PROBE
// File: tests/machine/x86_64/test_stack_probe.wl
// Focus: Touch every guard page before entering a large Win64 stack frame.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/machine/x86_64/lowering.wl"

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let byte_type: WirTypeID = wir_unsigned_int_type(ref program, 8);
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let array_type: WirTypeID = wir_array_type(ref program, byte_type, UIntSize(16384));
    let function_id: WirFuncID = wir_add_function(ref program, "main", [], int_type, false, WirLinkage.Exported, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    wir_stack_alloc(ref program, entry, array_type, "large", no_wir_location());
    wir_return(ref program, entry, wir_const_int(ref program, int_type, UInt128(0U)), no_wir_location());

    let lowered: X86LoweringResult = x86_lower_function(ref program, function_id);
    if (lowered.errors.length() != 0) {
        print("FAIL: x86_64 large stack frame lowering failed: ", lowered.errors[0]);
        return 1;
    }
    let probes: Int = 0;
    let i: Int = 0;
    while (i + 3 < lowered.bytes.length()) {
        if (lowered.bytes[i] == Byte(246) && lowered.bytes[i + 1] == Byte(4) && lowered.bytes[i + 2] == Byte(36) && lowered.bytes[i + 3] == Byte(0)) {
            probes++;
            i += 4;
        } else {
            i++;
        }
    }
    if (probes != 3) {
        print("FAIL: expected 3 stack probes, got ", probes);
        return 1;
    }
    print("PASS: x86_64 large stack probing");
    return 0;
}
