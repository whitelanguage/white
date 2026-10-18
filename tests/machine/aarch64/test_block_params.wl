// Test: AARCH64_BLOCK_PARAMETERS
// File: tests/machine/aarch64/test_block_params.wl
// Focus: Copy conditional edge arguments through homes before entering a block.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/machine/aarch64/lowering.wl"
import A64LoweringResult from "../../../src/compiler/machine/aarch64/model.wl"


func main() -> Int {
    let program: WirModule = new_wir_module("aarch64-unknown-linux-gnu", 64);
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let function_id: WirFuncID = wir_add_function(ref program, "select_value", [wir_param("choose_left", program.bool_type), wir_param("left", int_type), wir_param("right", int_type)], int_type, false, WirLinkage.Exported, WirABI.C);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let joined: WirBlockID = wir_add_block(ref program, function_id, "joined", [wir_param("value", int_type)]);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let joined_block: WirBlock = program.arena.blocks[wir_id_index(UInt32(joined))];

    wir_append(
        ref program,
        entry,
        WirOpcode.Branch,
        program.void_type,
        [function.parameters[0]],
        [wir_edge(joined, [function.parameters[1]]), wir_edge(joined, [function.parameters[2]])],
        no_wir_location()
    );
    wir_return(ref program, joined, joined_block.parameters[0], no_wir_location());

    let lowered: A64LoweringResult = a64_lower_function(ref program, function_id);
    if (lowered.errors.length() != 0) {
        print("FAIL: AArch64 block parameter lowering failed: ", lowered.errors[0]);
        return 1;
    }
    if (lowered.bytes.length() < 40 || lowered.bytes.length() % 4 != 0) {
        print("FAIL: AArch64 block parameter code was not emitted");
        return 1;
    }

    print("PASS: AArch64 block parameters");
    return 0;
}
