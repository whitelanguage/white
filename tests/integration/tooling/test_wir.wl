// Test: WIR_MODEL
// File: tests/integration/tooling/test_wir.wl
// Focus: WIR IDs, control flow and verifier checks remain consistent.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/verify.wl"

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc");
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    if (wir_signed_int_type(ref program, 32) != int_type) {
        print("FAIL: scalar types were not interned");
        return 1;
    }

    let node_type: WirTypeID = wir_declare_struct(ref program, "Node");
    let node_pointer: WirTypeID = wir_pointer_type(ref program, node_type);
    wir_define_struct(ref program, node_type, [int_type, node_pointer]);
    let function_id: WirFuncID = wir_add_function(ref program, "add", [int_type, int_type], int_type, false, WirLinkage.Internal);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let exit: WirBlockID = wir_add_block(ref program, function_id, "exit", [int_type]);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    if (wir_function_value(program, function_id) != function.address) {
        print("FAIL: function address was not stable");
        return 1;
    }
    let sum: WirValueID = wir_append(ref program, entry, WirOpcode.Add, int_type, [function.parameters[0], function.parameters[1]], [], no_wir_location());
    wir_append(ref program, entry, WirOpcode.Jump, program.void_type, [], [wir_edge(exit, [sum])], no_wir_location());
    let exit_block: WirBlock = program.arena.blocks[wir_id_index(UInt32(exit))];
    wir_append(ref program, exit, WirOpcode.Return, program.void_type, [exit_block.parameters[0]], [], no_wir_location());

    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: valid WIR was rejected: ", errors[0]);
        return 1;
    }

    let invalid: WirModule = new_wir_module("x86_64-pc-windows-msvc");
    let invalid_int: WirTypeID = wir_signed_int_type(ref invalid, 32);
    let invalid_function: WirFuncID = wir_add_function(ref invalid, "broken", [], invalid_int, false, WirLinkage.Internal);
    wir_add_block(ref invalid, invalid_function, "entry", []);
    let invalid_errors: Vector(String) = verify_wir(invalid);
    if (invalid_errors.length() == 0) {
        print("FAIL: unterminated WIR block was accepted");
        return 1;
    }

    print("PASS: WIR model and verifier");
    return 0;
}
