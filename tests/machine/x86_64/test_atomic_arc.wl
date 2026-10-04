// Test: X86_64_ATOMIC_ARC
// File: tests/machine/x86_64/test_atomic_arc.wl
// Focus: Native integer atomics and ownership runtime calls on Windows x86_64.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import verify_wir from "../../../src/compiler/wir/verify.wl"
import wir_emit_ownership_runtime from "../../../src/compiler/wir/lowering/ownership_runtime.wl"
import X86Object from "../../../src/compiler/machine/x86_64/model.wl"
import * from "../../../src/compiler/machine/x86_64/lowering.wl"
import coff_object from "../../../src/compiler/machine/x86_64/coff.wl"

func atomic_rmw(ref program: WirModule, name: String, i32: WirTypeID, pointer: WirTypeID, operation: WirAtomicOp) -> Void {
    let function: WirFuncID = wir_add_function(ref program, name, [WirParam(name="address", type_id=pointer), WirParam(name="value", type_id=i32)], i32, false, WirLinkage.Exported, WirABI.C);
    let entry: WirBlockID = wir_add_block(ref program, function, "entry", []);
    let parameters: Vector(WirValueID) = program.arena.functions[wir_id_index(UInt32(function))].parameters;
    let result: WirValueID = wir_atomic_rmw(ref program, entry, operation, parameters[0], parameters[1], WirMemoryOrder.SequentiallyConsistent, "old", no_wir_location());
    wir_return(ref program, entry, result, no_wir_location());
}

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let pointer: WirTypeID = wir_pointer_type(ref program, i32);
    let raw: WirTypeID = wir_pointer_type(ref program, program.void_type);

    atomic_rmw(ref program, "native_atomic_add", i32, pointer, WirAtomicOp.Add);
    atomic_rmw(ref program, "native_atomic_sub", i32, pointer, WirAtomicOp.Subtract);
    atomic_rmw(ref program, "native_atomic_exchange", i32, pointer, WirAtomicOp.Exchange);
    atomic_rmw(ref program, "native_atomic_and", i32, pointer, WirAtomicOp.BitAnd);
    atomic_rmw(ref program, "native_atomic_or", i32, pointer, WirAtomicOp.BitOr);
    atomic_rmw(ref program, "native_atomic_xor", i32, pointer, WirAtomicOp.BitXor);

    let load: WirFuncID = wir_add_function(ref program, "native_atomic_load", [WirParam(name="address", type_id=pointer)], i32, false, WirLinkage.Exported, WirABI.C);
    let load_entry: WirBlockID = wir_add_block(ref program, load, "entry", []);
    let load_address: WirValueID = program.arena.functions[wir_id_index(UInt32(load))].parameters[0];
    wir_return(ref program, load_entry, wir_atomic_load(ref program, load_entry, load_address, WirMemoryOrder.Acquire, "value", no_wir_location()), no_wir_location());

    let store: WirFuncID = wir_add_function(ref program, "native_atomic_store", [WirParam(name="address", type_id=pointer), WirParam(name="value", type_id=i32)], program.void_type, false, WirLinkage.Exported, WirABI.C);
    let store_entry: WirBlockID = wir_add_block(ref program, store, "entry", []);
    let store_parameters: Vector(WirValueID) = program.arena.functions[wir_id_index(UInt32(store))].parameters;
    wir_atomic_store(ref program, store_entry, store_parameters[1], store_parameters[0], WirMemoryOrder.SequentiallyConsistent, no_wir_location());
    wir_return(ref program, store_entry, NO_WIR_VALUE, no_wir_location());

    let ownership: WirFuncID = wir_add_function(ref program, "native_arc_roundtrip", [WirParam(name="object", type_id=raw)], program.void_type, false, WirLinkage.Exported, WirABI.C);
    let ownership_entry: WirBlockID = wir_add_block(ref program, ownership, "entry", []);
    let object: WirValueID = program.arena.functions[wir_id_index(UInt32(ownership))].parameters[0];
    wir_retain(ref program, ownership_entry, object, no_wir_location());
    wir_release(ref program, ownership_entry, object, no_wir_location());
    wir_return(ref program, ownership_entry, NO_WIR_VALUE, no_wir_location());

    let deallocator: WirFuncID = wir_add_function(ref program, "host_dealloc", [WirParam(name="object", type_id=raw)], program.void_type, false, WirLinkage.External, WirABI.C);
    wir_emit_ownership_runtime(ref program, deallocator, 5);

    let verify: WirFuncID = wir_add_function(ref program, "host_verify_atomic_arc", [], i32, false, WirLinkage.External, WirABI.C);
    let exit: WirFuncID = wir_add_function(ref program, "ExitProcess", [WirParam(name="status", type_id=i32)], program.void_type, false, WirLinkage.External, WirABI.System);
    let startup: WirFuncID = wir_add_function(ref program, "mainCRTStartup", [], program.void_type, false, WirLinkage.Exported, WirABI.White);
    let startup_entry: WirBlockID = wir_add_block(ref program, startup, "entry", []);
    let status: WirValueID = wir_call(ref program, startup_entry, wir_function_value(ref program, verify), [], "status", no_wir_location());
    wir_call(ref program, startup_entry, wir_function_value(ref program, exit), [status], "", no_wir_location());
    wir_append(ref program, startup_entry, WirOpcode.Unreachable, program.void_type, [], [], no_wir_location());

    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: atomic ARC WIR: ", errors[0]);
        return 1;
    }
    let lowered: X86ModuleResult = x86_lower_module(ref program);
    if (lowered.errors.length() != 0) {
        print("FAIL: atomic ARC lowering: ", lowered.errors[0]);
        return 1;
    }
    let object_file: Vector(Byte) = coff_object(X86Object(sections=lowered.sections, symbols=lowered.symbols, relocations=lowered.relocations))?;
    catch(err) {
        print("FAIL: atomic ARC object");
        return 1;
    }
    print("PASS: x86_64 atomic ARC");
    print("OBJECT-BEGIN");
    let i = 0;
    while (i < object_file.length()) {
        print(Int(object_file[i]));
        i++;
    }
    print("OBJECT-END");
    return 0;
}
