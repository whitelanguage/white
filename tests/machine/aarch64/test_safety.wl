// Test: AARCH64_SAFETY
// File: tests/machine/aarch64/test_safety.wl
// Focus: Encode trap and unreachable terminators as an architectural BRK.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import verify_wir from "../../../src/compiler/wir/verify.wl"
import * from "../../../src/compiler/machine/aarch64/lowering.wl"
import A64ModuleResult from "../../../src/compiler/machine/aarch64/model.wl"
import a64_lower_module from "../../../src/compiler/machine/aarch64/module.wl"


func has_break(bytes: Vector(Byte), offset: Int) -> Bool {
    return offset >= 0 && offset + 3 < bytes.length() &&
           bytes[offset] == Byte(0) && bytes[offset + 1] == Byte(0) &&
           bytes[offset + 2] == Byte(32) && bytes[offset + 3] == Byte(212);
}

func main() -> Int {
    let program: WirModule = new_wir_module("aarch64-unknown-linux-gnu", 64);
    let i64: WirTypeID = wir_signed_int_type(ref program, 64);
    let pointer: WirTypeID = wir_pointer_type(ref program, program.void_type);
    wir_add_function(ref program, "__wl_fail_null", [], program.void_type, false, WirLinkage.External, WirABI.C);
    wir_add_function(ref program, "__wl_fail_bounds", [], program.void_type, false, WirLinkage.External, WirABI.C);

    let checked: WirFuncID = wir_add_function(ref program, "checked", [WirParam(name="object", type_id=pointer), WirParam(name="index", type_id=i64), WirParam(name="limit", type_id=i64)], i64, false, WirLinkage.Exported, WirABI.C);
    let checked_entry: WirBlockID = wir_add_block(ref program, checked, "entry", []);
    let checked_params: Vector(WirValueID) = program.arena.functions[wir_id_index(UInt32(checked))].parameters;
    wir_append(ref program, checked_entry, WirOpcode.NullCheck, program.void_type, [checked_params[0]], [], no_wir_location());
    wir_append(ref program, checked_entry, WirOpcode.BoundsCheck, program.void_type, [checked_params[1], checked_params[2]], [], no_wir_location());
    wir_return(ref program, checked_entry, checked_params[1], no_wir_location());

    let trapped: WirFuncID = wir_add_function(ref program, "native_trap", [], program.void_type, false, WirLinkage.Exported, WirABI.C);
    let trap_entry: WirBlockID = wir_add_block(ref program, trapped, "entry", []);
    wir_trap(ref program, trap_entry, no_wir_location());

    let unreachable: WirFuncID = wir_add_function(ref program, "native_unreachable", [], program.void_type, false, WirLinkage.Exported, WirABI.C);
    let unreachable_entry: WirBlockID = wir_add_block(ref program, unreachable, "entry", []);
    wir_append(ref program, unreachable_entry, WirOpcode.Unreachable, program.void_type, [], [], no_wir_location());

    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: invalid AArch64 safety test: ", errors[0]);
        return 1;
    }

    let lowered: A64ModuleResult = a64_lower_module(ref program);
    if (lowered.errors.length() != 0) {
        print("FAIL: AArch64 safety lowering: ", lowered.errors[0]);
        return 1;
    }
    if (lowered.relocations.length() != 2 || lowered.relocations[0].symbol != "__wl_fail_null" ||
        lowered.relocations[1].symbol != "__wl_fail_bounds") {
        print("FAIL: AArch64 safety call relocations");
        return 1;
    }
    if (lowered.symbols.length() != 5 || !has_break(lowered.sections[0].bytes, Int(lowered.symbols[3].offset)) ||
        !has_break(lowered.sections[0].bytes, Int(lowered.symbols[4].offset))) {
        print("FAIL: AArch64 safety instructions");
        return 1;
    }

    print("PASS: AArch64 safety terminators");
    return 0;
}
