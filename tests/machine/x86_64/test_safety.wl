// Test: X86_64_SAFETY_CHECKS
// File: tests/machine/x86_64/test_safety.wl
// Focus: Native null, bounds and trap lowering for the Windows x86_64 backend.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import verify_wir from "../../../src/compiler/wir/verify.wl"
import X86Object from "../../../src/compiler/machine/x86_64/model.wl"
import * from "../../../src/compiler/machine/x86_64/lowering.wl"
import coff_object from "../../../src/compiler/machine/x86_64/coff.wl"

func checked_bounds(ref program: WirModule, name: String, type_id: WirTypeID) -> Void {
    let function: WirFuncID = wir_add_function(ref program, name, [WirParam(name="index", type_id=type_id), WirParam(name="limit", type_id=type_id)], type_id, false, WirLinkage.Exported, WirABI.C);
    let entry: WirBlockID = wir_add_block(ref program, function, "entry", []);
    let parameters: Vector(WirValueID) = program.arena.functions[wir_id_index(UInt32(function))].parameters;
    wir_append(ref program, entry, WirOpcode.BoundsCheck, program.void_type, [parameters[0], parameters[1]], [], no_wir_location());
    wir_return(ref program, entry, parameters[0], no_wir_location());
}

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let i64: WirTypeID = wir_signed_int_type(ref program, 64);
    let u64: WirTypeID = wir_unsigned_int_type(ref program, 64);
    let raw: WirTypeID = wir_pointer_type(ref program, program.void_type);

    let checked: WirFuncID = wir_add_function(ref program, "native_null_checked", [WirParam(name="value", type_id=raw)], raw, false, WirLinkage.Exported, WirABI.C);
    let checked_entry: WirBlockID = wir_add_block(ref program, checked, "entry", []);
    let checked_value: WirValueID = program.arena.functions[wir_id_index(UInt32(checked))].parameters[0];
    wir_append(ref program, checked_entry, WirOpcode.NullCheck, program.void_type, [checked_value], [], no_wir_location());
    wir_return(ref program, checked_entry, checked_value, no_wir_location());

    checked_bounds(ref program, "native_bounds_i64", i64);
    checked_bounds(ref program, "native_bounds_u64", u64);

    let trapped: WirFuncID = wir_add_function(ref program, "native_trap", [], program.void_type, false, WirLinkage.Exported, WirABI.C);
    let trapped_entry: WirBlockID = wir_add_block(ref program, trapped, "entry", []);
    wir_trap(ref program, trapped_entry, no_wir_location());

    let unreachable: WirFuncID = wir_add_function(ref program, "native_unreachable", [], program.void_type, false, WirLinkage.Exported, WirABI.C);
    let unreachable_entry: WirBlockID = wir_add_block(ref program, unreachable, "entry", []);
    wir_append(ref program, unreachable_entry, WirOpcode.Unreachable, program.void_type, [], [], no_wir_location());

    let verify: WirFuncID = wir_add_function(ref program, "host_verify_safety", [], i32, false, WirLinkage.External, WirABI.C);
    let exit: WirFuncID = wir_add_function(ref program, "ExitProcess", [WirParam(name="status", type_id=i32)], program.void_type, false, WirLinkage.External, WirABI.System);
    let startup: WirFuncID = wir_add_function(ref program, "mainCRTStartup", [], program.void_type, false, WirLinkage.Exported, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, startup, "entry", []);
    let status: WirValueID = wir_call(ref program, entry, wir_function_value(program, verify), [], "status", no_wir_location());
    wir_call(ref program, entry, wir_function_value(program, exit), [status], "", no_wir_location());
    wir_append(ref program, entry, WirOpcode.Unreachable, program.void_type, [], [], no_wir_location());

    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: safety WIR: ", errors[0]);
        return 1;
    }
    let lowered: X86ModuleResult = x86_lower_module(program);
    if (lowered.errors.length() != 0) {
        print("FAIL: safety lowering: ", lowered.errors[0]);
        return 1;
    }
    let object: Vector(Byte) = coff_object(X86Object(sections=lowered.sections, symbols=lowered.symbols, relocations=lowered.relocations))?;
    catch(err) {
        print("FAIL: safety object");
        return 1;
    }
    print("PASS: x86_64 safety checks");
    print("OBJECT-BEGIN");
    let i = 0;
    while (i < object.length()) {
        print(Int(object[i]));
        i++;
    }
    print("OBJECT-END");
    return 0;
}
