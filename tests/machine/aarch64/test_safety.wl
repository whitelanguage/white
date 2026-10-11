// Test: AARCH64_SAFETY
// File: tests/machine/aarch64/test_safety.wl
// Focus: Encode trap and unreachable terminators as an architectural BRK.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import verify_wir from "../../../src/compiler/wir/verify.wl"
import * from "../../../src/compiler/machine/aarch64/lowering.wl"


func has_break(bytes: Vector(Byte), offset: Int) -> Bool {
    return offset >= 0 && offset + 3 < bytes.length() &&
           bytes[offset] == Byte(0) && bytes[offset + 1] == Byte(0) &&
           bytes[offset + 2] == Byte(32) && bytes[offset + 3] == Byte(212);
}

func main() -> Int {
    let program: WirModule = new_wir_module("aarch64-unknown-linux-gnu", 64);
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
    if (lowered.symbols.length() != 2 || !has_break(lowered.sections[0].bytes, Int(lowered.symbols[0].offset)) ||
        !has_break(lowered.sections[0].bytes, Int(lowered.symbols[1].offset))) {
        print("FAIL: AArch64 safety instructions");
        return 1;
    }

    print("PASS: AArch64 safety terminators");
    return 0;
}
