// Test: AARCH64_NEXT_USE
// File: tests/machine/aarch64/test_allocator.wl
// Focus: Record WIR operand uses once and advance each value queue while lowering.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import A64Register from "../../../src/compiler/machine/aarch64/model.wl"
import * from "../../../src/compiler/machine/aarch64/allocator.wl"


func policy(ref program: WirModule, ref values: A64ValueMap, plain: WirValueID, constant: WirValueID) -> Bool {
    let i = 0;
    for (i = 0; i < values.bindings.length(); i++) {
        values.bindings[i].held = true;
    }
    if (a64_select_register(ref program, ref values, false) != -1 ||
        a64_select_register(ref program, ref values, true) != -1) {
        return false;
    }
    for (i = 0; i < values.bindings.length(); i++) {
        if (!values.bindings[i].held) { return false; }
    }

    values.bindings[1].held = false;
    values.bindings[8].held = false;
    if (a64_select_register(ref program, ref values, false) != 1 ||
        a64_select_register(ref program, ref values, true) != 8) {
        return false;
    }

    values.bindings[8].held = true;
    values.bindings[0].held = false;
    values.bindings[0].value = plain;
    values.bindings[1].value = constant;
    values.position = A64_NO_NEXT_USE;
    if (a64_select_register(ref program, ref values, false) != 1) { return false; }

    values.bindings[7].held = false;
    values.bindings[8].held = false;
    values.bindings[7].value = plain;
    values.bindings[8].value = constant;
    if (a64_select_register(ref program, ref values, true) != 8) { return false; }

    a64_reset_temporaries(ref values);
    return true;
}

func main() -> Int {
    let program: WirModule = new_wir_module("aarch64-unknown-linux-gnu", 64);
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let noise: Int = 0;
    while (noise < 4096) {
        wir_const_int(ref program, int_type, UInt128(UInt32(noise + 100)));
        noise++;
    }
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

    noise = 0;
    while (noise < 4096) {
        wir_const_int(ref program, int_type, UInt128(UInt32(noise + 10000)));
        noise++;
    }

    let values: A64ValueMap = a64_new_value_map(ref program, function.blocks);
    if (values.registers.length() != values.uses.queues.length() || values.registers.length() > 16 ||
        values.wide_high.length() != values.registers.length()) {
        print("FAIL: unrelated module values enlarged the register map");
        return 1;
    }
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
    let binding_index: Int = a64_select_register(ref program, ref values, false);
    let value_register: A64Register = a64_claim_register(ref values, binding_index);
    if (value_register == A64Register.None || !a64_bind_value(ref values, value, value_register, false) ||
        a64_mapped_register(ref values, value) != value_register) {
        print("FAIL: AArch64 value was not bound to its register");
        return 1;
    }

    a64_finish_instruction(ref values, first_instruction);

    if (values.position != 1 || a64_next_use(ref values.uses, value, 0) != 1 ||
        a64_next_use(ref values.uses, one, 0) != A64_NO_NEXT_USE ||
        a64_mapped_register(ref values, value) != value_register) {
        print("FAIL: AArch64 next-use cursor did not advance");
        return 1;
    }

    let second_instruction: WirInstruction = program.arena.instructions[
        wir_id_index(UInt32(block.instructions[1]))
    ];
    a64_finish_instruction(ref values, second_instruction);
    if (a64_next_use(ref values.uses, value, 1) != A64_NO_NEXT_USE ||
        a64_mapped_register(ref values, value) != A64Register.None) {
        print("FAIL: AArch64 value remained live after its last use");
        return 1;
    }

    let low_index: Int = a64_select_register(ref program, ref values, false);
    let low: A64Register = a64_claim_register(ref values, low_index);
    let high_index: Int = a64_select_register(ref program, ref values, false);
    let high: A64Register = a64_claim_register(ref values, high_index);
    if (!a64_bind_register_pair(ref values, first, low, high, true)) {
        print("FAIL: AArch64 register pair was not bound");
        return 1;
    }

    let pair: A64RegisterPair = a64_mapped_register_pair(ref values, first);
    if (pair.low != low || pair.high != high ||
        !values.bindings[a64_binding_index(ref values, low)].dirty ||
        !values.bindings[a64_binding_index(ref values, high)].dirty) {
        print("FAIL: AArch64 register pair mapping was incomplete");
        return 1;
    }

    a64_release_binding(ref values, a64_binding_index(ref values, low));
    pair = a64_mapped_register_pair(ref values, first);
    if (pair.low != A64Register.None || pair.high != A64Register.None ||
        values.bindings[a64_binding_index(ref values, high)].value != NO_WIR_VALUE) {
        print("FAIL: AArch64 register pair was only half released");
        return 1;
    }

    if (!policy(ref program, ref values, first, one)) {
        print("FAIL: AArch64 eviction ties or held register exhaustion");
        return 1;
    }

    print("PASS: AArch64 next-use table");
    return 0;
}
