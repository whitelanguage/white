// Test: AARCH64_INTEGER_DIVISION
// File: tests/machine/aarch64/test_division.wl
// Focus: Lower signed and unsigned quotient and remainder instructions.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/machine/aarch64/lowering.wl"


func main() -> Int {
    let program: WirModule = new_wir_module("aarch64-unknown-linux-gnu", 64);
    let i64: WirTypeID = wir_signed_int_type(ref program, 64);
    let function_id: WirFuncID = wir_add_function(ref program, "signed_math", [wir_param("left", i64), wir_param("right", i64)], i64, false, WirLinkage.Exported, WirABI.C);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let quotient: WirValueID = wir_binary(ref program, entry, WirOpcode.SignedDivide, i64, function.parameters[0], function.parameters[1], "quotient", no_wir_location());
    let remainder: WirValueID = wir_binary(ref program, entry, WirOpcode.SignedRemainder, i64, function.parameters[0], function.parameters[1], "remainder", no_wir_location());
    let result: WirValueID = wir_binary(ref program, entry, WirOpcode.Add, i64, quotient, remainder, "result", no_wir_location());
    wir_return(ref program, entry, result, no_wir_location());

    let lowered: A64LoweringResult = a64_lower_function(ref program, function_id);
    if (lowered.errors.length() != 0) {
        print("FAIL: AArch64 integer division failed: ", lowered.errors[0]);
        return 1;
    }
    if (lowered.bytes.length() < 48 || lowered.bytes.length() % 4 != 0) {
        print("FAIL: unexpected AArch64 integer division size: ", lowered.bytes.length());
        return 1;
    }

    print("PASS: AArch64 integer division");
    return 0;
}
