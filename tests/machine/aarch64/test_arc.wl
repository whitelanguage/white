// Test: AARCH64_ARC
// File: tests/machine/aarch64/test_arc.wl
// Focus: Lower retain and release operations through the common ARC runtime ABI.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import verify_wir from "../../../src/compiler/wir/verify.wl"
import A64RelocationKind from "../../../src/compiler/machine/aarch64/model.wl"
import * from "../../../src/compiler/machine/aarch64/lowering.wl"
import A64ModuleResult from "../../../src/compiler/machine/aarch64/model.wl"
import a64_lower_module from "../../../src/compiler/machine/aarch64/module.wl"


func main() -> Int {
    let program: WirModule = new_wir_module("aarch64-unknown-linux-gnu", 64);
    let pointer: WirTypeID = wir_pointer_type(ref program, program.void_type);
    wir_add_function(ref program, "__wl_retain", [WirParam(name="object", type_id=pointer)], program.void_type, false, WirLinkage.External, WirABI.C);
    wir_add_function(ref program, "__wl_release", [WirParam(name="object", type_id=pointer)], program.void_type, false, WirLinkage.External, WirABI.C);

    let function: WirFuncID = wir_add_function(ref program, "arc_pair", [WirParam(name="object", type_id=pointer)], program.void_type, false, WirLinkage.Exported, WirABI.C);
    let block: WirBlockID = wir_add_block(ref program, function, "entry", []);
    let object: WirValueID = program.arena.functions[wir_id_index(UInt32(function))].parameters[0];
    wir_retain(ref program, block, object, no_wir_location());
    wir_release(ref program, block, object, no_wir_location());
    wir_return(ref program, block, NO_WIR_VALUE, no_wir_location());

    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: invalid AArch64 ARC test: ", errors[0]);
        return 1;
    }

    let lowered: A64ModuleResult = a64_lower_module(ref program);
    if (lowered.errors.length() != 0) {
        print("FAIL: AArch64 ARC lowering: ", lowered.errors[0]);
        return 1;
    }
    if (lowered.relocations.length() != 2 || lowered.relocations[0].kind != A64RelocationKind.Call26 ||
        lowered.relocations[0].symbol != "__wl_retain" || lowered.relocations[1].kind != A64RelocationKind.Call26 ||
        lowered.relocations[1].symbol != "__wl_release") {
        print("FAIL: AArch64 ARC call relocations");
        return 1;
    }

    print("PASS: AArch64 ARC calls");
    return 0;
}
