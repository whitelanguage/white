// Test: AARCH64_NEXT_USE
// File: tests/machine/aarch64/test_allocator.wl
// Focus: Record WIR operand uses once and advance each value queue while lowering.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/machine/aarch64/allocator.wl"


func main() -> Int {
    let program: WirModule = new_wir_module("aarch64-unknown-linux-gnu", 64);
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let function_id: WirFuncID = wir_add_function(
        ref program,
        "uses",
        [wir_param("value", int_type)],
        int_type,
        false,
        WirLinkage.Internal,
        WirABI.White
    );
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let value: WirValueID = function.parameters[0];
    let one: WirValueID = wir_const_int(ref program, int_type, UInt128(1U));
    let first: WirValueID = wir_binary(
        ref program,
        entry,
        WirOpcode.Add,
        int_type,
        value,
        one,
        "",
        no_wir_location()
    );
    let second: WirValueID = wir_binary(
        ref program,
        entry,
        WirOpcode.Add,
        int_type,
        first,
        value,
        "",
        no_wir_location()
    );
    wir_return(ref program, entry, second, no_wir_location());

    let values: A64ValueMap = a64_new_value_map(ref program, function.blocks);
    if (a64_next_use(ref values.uses, value, -1) != 0 ||
        a64_next_use(ref values.uses, first, -1) != 1 ||
        a64_next_use(ref values.uses, second, -1) != 2) {
        print("FAIL: AArch64 next-use positions were recorded incorrectly");
        return 1;
    }

    let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(entry))];
    let first_instruction: WirInstruction = program.arena.instructions[
        wir_id_index(UInt32(block.instructions[0]))
    ];
    a64_finish_instruction(ref values, first_instruction);

    if (values.position != 1 || a64_next_use(ref values.uses, value, 0) != 1 ||
        a64_next_use(ref values.uses, one, 0) != A64_NO_NEXT_USE) {
        print("FAIL: AArch64 next-use cursor did not advance");
        return 1;
    }

    let second_instruction: WirInstruction = program.arena.instructions[
        wir_id_index(UInt32(block.instructions[1]))
    ];
    a64_finish_instruction(ref values, second_instruction);
    if (a64_next_use(ref values.uses, value, 1) != A64_NO_NEXT_USE) {
        print("FAIL: AArch64 value remained live after its last use");
        return 1;
    }

    print("PASS: AArch64 next-use table");
    return 0;
}
