// Test: AARCH64_DIRECT_CALLS
// File: tests/machine/aarch64/test_calls.wl
// Focus: Preserve the link register and emit CALL26 for a direct WIR call.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/machine/aarch64/model.wl"
import * from "../../../src/compiler/machine/aarch64/lowering.wl"
import a64_elf_object from "../../../src/compiler/machine/aarch64/elf.wl"


func main() -> Int {
    let program: WirModule = new_wir_module("aarch64-unknown-linux-gnu", 64);
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let caller_id: WirFuncID = wir_add_function(ref program, "caller", [], int_type, false, WirLinkage.Exported, WirABI.C);
    let caller_entry: WirBlockID = wir_add_block(ref program, caller_id, "entry", []);
    let helper_id: WirFuncID = wir_add_function(ref program, "helper", [wir_param("left", int_type), wir_param("right", int_type)], int_type, false, WirLinkage.Internal, WirABI.C);
    let helper_entry: WirBlockID = wir_add_block(ref program, helper_id, "entry", []);
    let helper: WirFunction = program.arena.functions[wir_id_index(UInt32(helper_id))];

    let helper_result: WirValueID = wir_binary(ref program, helper_entry, WirOpcode.Add, int_type, helper.parameters[0], helper.parameters[1], "result", no_wir_location());
    wir_return(ref program, helper_entry, helper_result, no_wir_location());
    let value: WirValueID = wir_call(
        ref program,
        caller_entry,
        program.arena.functions[wir_id_index(UInt32(helper_id))].address,
        [wir_const_int(ref program, int_type, UInt128(2U)), wir_const_int(ref program, int_type, UInt128(5U))],
        "value",
        no_wir_location()
    );
    let answer: WirValueID = wir_binary(
        ref program,
        caller_entry,
        WirOpcode.Add,
        int_type,
        value,
        wir_const_int(ref program, int_type, UInt128(35U)),
        "answer",
        no_wir_location()
    );
    wir_return(ref program, caller_entry, answer, no_wir_location());

    let pointer_type: WirTypeID = wir_pointer_type(ref program, int_type);
    let load_id: WirFuncID = wir_add_function(ref program, "load_pointer", [wir_param("value", pointer_type)], int_type, false, WirLinkage.Internal, WirABI.C);
    let load_entry: WirBlockID = wir_add_block(ref program, load_id, "entry", []);
    let load_pointer: WirValueID = program.arena.functions[wir_id_index(UInt32(load_id))].parameters[0];
    let loaded: WirValueID = wir_load(ref program, load_entry, load_pointer, "loaded", no_wir_location());
    wir_return(ref program, load_entry, loaded, no_wir_location());

    let pointer_caller: WirFuncID = wir_add_function(ref program, "pointer_caller", [], int_type, false, WirLinkage.Exported, WirABI.C);
    let pointer_entry: WirBlockID = wir_add_block(ref program, pointer_caller, "entry", []);
    let slot: WirValueID = wir_stack_alloc(ref program, pointer_entry, int_type, "slot", no_wir_location());
    wir_store(ref program, pointer_entry, wir_const_int(ref program, int_type, UInt128(42U)), slot, no_wir_location());
    let pointer_result: WirValueID = wir_call(
        ref program,
        pointer_entry,
        program.arena.functions[wir_id_index(UInt32(load_id))].address,
        [slot],
        "result",
        no_wir_location()
    );
    wir_return(ref program, pointer_entry, pointer_result, no_wir_location());

    let unary_type: WirTypeID = wir_function_type(ref program, [int_type], int_type, false, WirABI.C);
    let apply_id: WirFuncID = wir_add_function(ref program, "apply", [wir_param("function", unary_type), wir_param("value", int_type)], int_type, false, WirLinkage.Exported, WirABI.C);
    let apply_entry: WirBlockID = wir_add_block(ref program, apply_id, "entry", []);
    let apply: WirFunction = program.arena.functions[wir_id_index(UInt32(apply_id))];
    let applied: WirValueID = wir_call_typed(ref program, apply_entry, apply.parameters[0], unary_type, [apply.parameters[1]], "applied", no_wir_location());
    wir_return(ref program, apply_entry, applied, no_wir_location());

    let lowered: A64ModuleResult = a64_lower_module(ref program);
    if (lowered.errors.length() != 0) {
        print("FAIL: AArch64 direct call lowering failed: ", lowered.errors[0]);
        return 1;
    }
    if (lowered.relocations.length() != 2 || lowered.relocations[0].kind != A64RelocationKind.Call26 ||
        lowered.relocations[0].symbol != "helper" || lowered.relocations[1].kind != A64RelocationKind.Call26 ||
        lowered.relocations[1].symbol != "load_pointer") {
        print("FAIL: AArch64 direct call relocation is missing");
        return 1;
    }

    a64_elf_object(A64Object(sections=lowered.sections, symbols=lowered.symbols, relocations=lowered.relocations))?;
    catch(err) {
        print("FAIL: AArch64 direct call object could not be encoded");
        return 1;
    }

    print("PASS: AArch64 direct call lowering");
    return 0;
}
