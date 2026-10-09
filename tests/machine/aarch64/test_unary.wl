// Test: AARCH64_INTEGER_UNARY
// File: tests/machine/aarch64/test_unary.wl
// Focus: Lower integer negation, complement, Bool not and branchless abs.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/machine/aarch64/lowering.wl"


func main() -> Int {
    let program: WirModule = new_wir_module("aarch64-unknown-linux-gnu", 64);
    let i64: WirTypeID = wir_signed_int_type(ref program, 64);
    let function_id: WirFuncID = wir_add_function(ref program, "integer_unary", [wir_param("value", i64)], i64, false, WirLinkage.Exported, WirABI.C);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let parameter: WirValueID = program.arena.functions[wir_id_index(UInt32(function_id))].parameters[0];
    let negative: WirValueID = wir_unary(ref program, entry, WirOpcode.Negate, i64, parameter, "negative", no_wir_location());
    let inverted: WirValueID = wir_unary(ref program, entry, WirOpcode.Not, i64, negative, "inverted", no_wir_location());
    let absolute: WirValueID = wir_unary(ref program, entry, WirOpcode.Abs, i64, inverted, "absolute", no_wir_location());
    wir_return(ref program, entry, absolute, no_wir_location());

    let lowered: A64LoweringResult = a64_lower_function(ref program, function_id);
    if (lowered.errors.length() != 0) {
        print("FAIL: AArch64 integer unary lowering failed: ", lowered.errors[0]);
        return 1;
    }
    if (lowered.bytes.length() < 40 || lowered.bytes.length() % 4 != 0) {
        print("FAIL: unexpected AArch64 integer unary size: ", lowered.bytes.length());
        return 1;
    }

    print("PASS: AArch64 integer unary operations");
    return 0;
}
