// Test: X86_64_REGISTER_COALESCING
// File: tests/machine/x86_64/test_coalescing.wl
// Focus: Keep incoming operands and returned results in their ABI registers.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/machine/x86_64/lowering.wl"
import X86LoweringResult from "../../../src/compiler/machine/x86_64/model.wl"

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let function_id: WirFuncID = wir_add_function(ref program, "abs", [wir_param("value", i32)], i32, false, WirLinkage.Exported, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let result: WirValueID = wir_unary(ref program, entry, WirOpcode.Abs, i32, function.parameters[0], "result", no_wir_location());
    wir_return(ref program, entry, result, no_wir_location());

    let lowered: X86LoweringResult = x86_lower_function(ref program, function_id);
    if (lowered.errors.length() != 0) {
        print("FAIL: x86_64 register coalescing failed: ", lowered.errors[0]);
        return 1;
    }

    let expected: Vector(Byte) = [Byte(137), Byte(200), Byte(247), Byte(216), Byte(15), Byte(72), Byte(193), Byte(195)];
    if (lowered.bytes.length() != expected.length()) {
        print("FAIL: coalesced abs has an unexpected instruction count");
        return 1;
    }
    let i: Int = 0;
    while (i < expected.length()) {
        if (lowered.bytes[i] != expected[i]) {
            print("FAIL: coalesced abs has an unexpected encoding");
            return 1;
        }
        i++;
    }

    print("PASS: x86_64 register coalescing");
    return 0;
}
