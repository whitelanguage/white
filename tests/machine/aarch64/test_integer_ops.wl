// Test: AARCH64_INTEGER_OPERATIONS
// File: tests/machine/aarch64/test_integer_ops.wl
// Focus: Lower multiply, bitwise operations and variable shifts without helpers.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/machine/aarch64/lowering.wl"
import A64LoweringResult from "../../../src/compiler/machine/aarch64/model.wl"


func main() -> Int {
    let program: WirModule = new_wir_module("aarch64-unknown-linux-gnu", 64);
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let function_id: WirFuncID = wir_add_function(ref program, "integer_ops", [wir_param("left", int_type), wir_param("right", int_type)], int_type, false, WirLinkage.Exported, WirABI.C);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let product: WirValueID = wir_binary(ref program, entry, WirOpcode.Multiply, int_type, function.parameters[0], function.parameters[1], "product", no_wir_location());
    let mixed: WirValueID = wir_binary(ref program, entry, WirOpcode.BitXor, int_type, product, wir_const_int(ref program, int_type, UInt128(3U)), "mixed", no_wir_location());
    let shifted: WirValueID = wir_binary(ref program, entry, WirOpcode.ShiftLeft, int_type, mixed, wir_const_int(ref program, int_type, UInt128(1U)), "shifted", no_wir_location());
    wir_return(ref program, entry, shifted, no_wir_location());

    let lowered: A64LoweringResult = a64_lower_function(ref program, function_id);
    if (lowered.errors.length() != 0) {
        print("FAIL: AArch64 integer operation lowering failed: ", lowered.errors[0]);
        return 1;
    }
    if (lowered.bytes.length() < 28 || lowered.bytes.length() % 4 != 0) {
        print("FAIL: unexpected AArch64 integer operation size: ", lowered.bytes.length());
        return 1;
    }

    print("PASS: AArch64 integer operations");
    return 0;
}
