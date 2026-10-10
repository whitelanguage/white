// Test: AARCH64_WIDE_INTEGER_ABI
// File: tests/machine/aarch64/test_wide_integer.wl
// Focus: Pass, return and copy 128-bit integers as AAPCS64 register pairs.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import A64RelocationKind from "../../../src/compiler/machine/aarch64/model.wl"
import * from "../../../src/compiler/machine/aarch64/lowering.wl"


func main() -> Int {
    let program: WirModule = new_wir_module("aarch64-unknown-linux-gnu", 64);
    let u128: WirTypeID = wir_unsigned_int_type(ref program, 128);

    let echo: WirFuncID = wir_add_function(ref program, "echo128", [wir_param("value", u128)], u128, false, WirLinkage.Exported, WirABI.C);
    let echo_entry: WirBlockID = wir_add_block(ref program, echo, "entry", []);
    let echo_value: WirValueID = program.arena.functions[wir_id_index(UInt32(echo))].parameters[0];
    wir_return(ref program, echo_entry, echo_value, no_wir_location());

    let memory: WirFuncID = wir_add_function(ref program, "memory128", [wir_param("value", u128)], u128, false, WirLinkage.Exported, WirABI.C);
    let memory_entry: WirBlockID = wir_add_block(ref program, memory, "entry", []);
    let memory_value: WirValueID = program.arena.functions[wir_id_index(UInt32(memory))].parameters[0];
    let slot: WirValueID = wir_stack_alloc(ref program, memory_entry, u128, "slot", no_wir_location());
    wir_store(ref program, memory_entry, memory_value, slot, no_wir_location());
    let loaded: WirValueID = wir_load(ref program, memory_entry, slot, "loaded", no_wir_location());
    wir_return(ref program, memory_entry, loaded, no_wir_location());

    let relay: WirFuncID = wir_add_function(ref program, "relay128", [wir_param("value", u128)], u128, false, WirLinkage.Exported, WirABI.C);
    let relay_entry: WirBlockID = wir_add_block(ref program, relay, "entry", []);
    let relay_value: WirValueID = program.arena.functions[wir_id_index(UInt32(relay))].parameters[0];
    let call_result: WirValueID = wir_call(ref program, relay_entry, wir_function_value(ref program, echo), [relay_value], "result", no_wir_location());
    wir_return(ref program, relay_entry, call_result, no_wir_location());

    let lowered: A64ModuleResult = a64_lower_module(ref program);
    if (lowered.errors.length() != 0) {
        print("FAIL: AArch64 128-bit ABI lowering failed: ", lowered.errors[0]);
        return 1;
    }
    if (lowered.symbols.length() != 3 || lowered.sections.length() == 0 ||
        lowered.relocations.length() != 1 || lowered.relocations[0].kind != A64RelocationKind.Call26) {
        print("FAIL: AArch64 128-bit functions were not emitted");
        return 1;
    }

    print("PASS: AArch64 128-bit register ABI");
    return 0;
}
