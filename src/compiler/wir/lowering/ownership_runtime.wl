// compiler/wir/lowering/ownership_runtime.wl

import * from "../model.wl"
import * from "../builder.wl"
import wir_find_function from "declarations.wl"

func wir_emit_retain_runtime(ref program: WirModule, raw_pointer: WirTypeID) -> Void {
    if (wir_find_function(program, "__wl_retain") != NO_WIR_FUNC) { return; }

    let i32_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let refcount_pointer: WirTypeID = wir_pointer_type(ref program, i32_type);
    let function_id: WirFuncID = wir_add_function(ref program, "__wl_retain", [wir_param("object", raw_pointer)], program.void_type, false, WirLinkage.Internal, WirABI.White);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let object: WirValueID = function.parameters[0];
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let work: WirBlockID = wir_add_block(ref program, function_id, "work", []);
    let retain: WirBlockID = wir_add_block(ref program, function_id, "retain", []);
    let trap: WirBlockID = wir_add_block(ref program, function_id, "trap", []);
    let done: WirBlockID = wir_add_block(ref program, function_id, "done", []);
    let zero: WirValueID = wir_const_int(ref program, i32_type, UInt128(0U));
    let one: WirValueID = wir_const_int(ref program, i32_type, UInt128(1U));
    let static_refcount: WirValueID = wir_const_int(ref program, i32_type, UInt128(UInt32(4294967295U)));

    let is_null: WirValueID = wir_binary(ref program, entry, WirOpcode.Equal, program.bool_type, object, wir_null(ref program, raw_pointer), "is.null", no_wir_location());
    wir_append(ref program, entry, WirOpcode.Branch, program.void_type, [is_null], [wir_edge(done, []), wir_edge(work, [])], no_wir_location());

    let refcount_address: WirValueID = wir_pointer_offset(ref program, work, object, -8, refcount_pointer);
    let refcount: WirValueID = wir_atomic_load(ref program, work, refcount_address, WirMemoryOrder.Relaxed, "refcount", no_wir_location());
    let is_static: WirValueID = wir_binary(ref program, work, WirOpcode.Equal, program.bool_type, refcount, static_refcount, "is.static", no_wir_location());
    wir_append(ref program, work, WirOpcode.Branch, program.void_type, [is_static], [wir_edge(done, []), wir_edge(retain, [])], no_wir_location());

    let old: WirValueID = wir_atomic_rmw(ref program, retain, WirAtomicOp.Add, refcount_address, one, WirMemoryOrder.Relaxed, "old", no_wir_location());
    let invalid: WirValueID = wir_binary(ref program, retain, WirOpcode.SignedLess, program.bool_type, old, zero, "invalid", no_wir_location());
    wir_append(ref program, retain, WirOpcode.Branch, program.void_type, [invalid], [wir_edge(trap, []), wir_edge(done, [])], no_wir_location());

    wir_trap(ref program, trap, no_wir_location());
    wir_return(ref program, done, NO_WIR_VALUE, no_wir_location());
}

func wir_emit_release_runtime(ref program: WirModule, deallocator: WirFuncID, raw_pointer: WirTypeID, string_type_tag: Int) -> Void {
    if (wir_find_function(program, "__wl_release") != NO_WIR_FUNC) { return; }

    let i32_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let refcount_pointer: WirTypeID = wir_pointer_type(ref program, i32_type);
    let raw_pointer_pointer: WirTypeID = wir_pointer_type(ref program, raw_pointer);
    let drop_type: WirTypeID = wir_function_type(ref program, [raw_pointer], program.void_type, false, WirABI.White);
    let function_id: WirFuncID = wir_add_function(ref program, "__wl_release", [wir_param("object", raw_pointer)], program.void_type, false, WirLinkage.Internal, WirABI.White);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let object: WirValueID = function.parameters[0];
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let work: WirBlockID = wir_add_block(ref program, function_id, "work", []);
    let release: WirBlockID = wir_add_block(ref program, function_id, "release", []);
    let trap: WirBlockID = wir_add_block(ref program, function_id, "trap", []);
    let check_last: WirBlockID = wir_add_block(ref program, function_id, "check.last", []);
    let destroy: WirBlockID = wir_add_block(ref program, function_id, "destroy", []);
    let destroy_dynamic: WirBlockID = wir_add_block(ref program, function_id, "destroy.dynamic", []);
    let destroy_legacy: WirBlockID = wir_add_block(ref program, function_id, "destroy.legacy", []);
    let done: WirBlockID = wir_add_block(ref program, function_id, "done", []);
    let zero: WirValueID = wir_const_int(ref program, i32_type, UInt128(0U));
    let one: WirValueID = wir_const_int(ref program, i32_type, UInt128(1U));
    let static_refcount: WirValueID = wir_const_int(ref program, i32_type, UInt128(UInt32(4294967295U)));

    let is_null: WirValueID = wir_binary(ref program, entry, WirOpcode.Equal, program.bool_type, object, wir_null(ref program, raw_pointer), "is.null", no_wir_location());
    wir_append(ref program, entry, WirOpcode.Branch, program.void_type, [is_null], [wir_edge(done, []), wir_edge(work, [])], no_wir_location());

    let refcount_address: WirValueID = wir_pointer_offset(ref program, work, object, -8, refcount_pointer);
    let refcount: WirValueID = wir_atomic_load(ref program, work, refcount_address, WirMemoryOrder.Relaxed, "refcount", no_wir_location());
    let is_static: WirValueID = wir_binary(ref program, work, WirOpcode.Equal, program.bool_type, refcount, static_refcount, "is.static", no_wir_location());
    wir_append(ref program, work, WirOpcode.Branch, program.void_type, [is_static], [wir_edge(done, []), wir_edge(release, [])], no_wir_location());

    let old: WirValueID = wir_atomic_rmw(ref program, release, WirAtomicOp.Subtract, refcount_address, one, WirMemoryOrder.AcquireRelease, "old", no_wir_location());
    let invalid: WirValueID = wir_binary(ref program, release, WirOpcode.SignedLessEqual, program.bool_type, old, zero, "invalid", no_wir_location());
    wir_append(ref program, release, WirOpcode.Branch, program.void_type, [invalid], [wir_edge(trap, []), wir_edge(check_last, [])], no_wir_location());

    wir_trap(ref program, trap, no_wir_location());

    let is_last: WirValueID = wir_binary(ref program, check_last, WirOpcode.Equal, program.bool_type, old, one, "is.last", no_wir_location());
    wir_append(ref program, check_last, WirOpcode.Branch, program.void_type, [is_last], [wir_edge(destroy, []), wir_edge(done, [])], no_wir_location());

    let tag_address: WirValueID = wir_pointer_offset(ref program, destroy, object, -4, refcount_pointer);
    let tag: WirValueID = wir_load(ref program, destroy, tag_address, "type.tag", no_wir_location());
    let string_tag: WirValueID = wir_const_int(ref program, i32_type, UInt128(UInt32(string_type_tag)));
    let is_dynamic: WirValueID = wir_binary(ref program, destroy, WirOpcode.NotEqual, program.bool_type, tag, string_tag, "is.dynamic", no_wir_location());
    wir_append(ref program, destroy, WirOpcode.Branch, program.void_type, [is_dynamic], [wir_edge(destroy_dynamic, []), wir_edge(destroy_legacy, [])], no_wir_location());

    let raw: WirValueID = wir_pointer_offset(ref program, destroy_dynamic, object, -16, raw_pointer);
    let drop_slot: WirValueID = wir_cast(ref program, destroy_dynamic, raw, raw_pointer_pointer, "", no_wir_location());
    let drop_address: WirValueID = wir_load(ref program, destroy_dynamic, drop_slot, "drop", no_wir_location());
    wir_call_typed(ref program, destroy_dynamic, drop_address, drop_type, [object], "", no_wir_location());
    wir_call(ref program, destroy_dynamic, wir_function_value(program, deallocator), [raw], "", no_wir_location());
    wir_append(ref program, destroy_dynamic, WirOpcode.Jump, program.void_type, [], [wir_edge(done, [])], no_wir_location());

    let legacy_base: WirValueID = wir_pointer_offset(ref program, destroy_legacy, object, -8, raw_pointer);
    wir_call(ref program, destroy_legacy, wir_function_value(program, deallocator), [legacy_base], "", no_wir_location());
    wir_append(ref program, destroy_legacy, WirOpcode.Jump, program.void_type, [], [wir_edge(done, [])], no_wir_location());

    wir_return(ref program, done, NO_WIR_VALUE, no_wir_location());
}

func wir_emit_ownership_runtime(ref program: WirModule, deallocator: WirFuncID, string_type_tag: Int) -> Void {
    if (!wir_module_uses_opcode(program, WirOpcode.Retain) && !wir_module_uses_opcode(program, WirOpcode.Release)) { return; }
    let raw_pointer: WirTypeID = wir_pointer_type(ref program, program.void_type);
    wir_emit_retain_runtime(ref program, raw_pointer);
    wir_emit_release_runtime(ref program, deallocator, raw_pointer, string_type_tag);
}
