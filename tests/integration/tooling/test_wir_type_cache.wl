// Test: WIR_TYPE_CACHE
// File: tests/integration/tooling/test_wir_type_cache.wl
// Focus: Stable type identity and layout invalidation after forward declarations.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/lowering/types.wl"

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let types: WirTypeMap = new_wir_type_map();
    let integer: WirTypeID = wir_signed_int_type(ref program, 32);
    let pointer: WirTypeID = wir_pointer_type(ref program, integer);
    let array: WirTypeID = wir_array_type(ref program, integer, UIntSize(12U));
    let signature: WirTypeID = wir_function_type(ref program, [integer, pointer], integer, false, WirABI.White);
    let inner: WirTypeID = wir_declare_struct(ref program, "Inner");
    let outer: WirTypeID = wir_struct_type(ref program, [inner]);
    let pending: WirTypeLayout = wir_lowering_layout(ref types, program, outer);
    if (pending.valid) {
        print("FAIL: incomplete field has a cached layout");
        return 1;
    }
    wir_define_struct(ref program, inner, [integer]);
    let complete: WirTypeLayout = wir_lowering_layout(ref types, program, outer);
    if (!complete.valid || complete.size != 4UL || complete.alignment != 4) {
        print("FAIL: forward declaration did not invalidate dependent layouts");
        return 1;
    }
    let i: Int = 0;
    while (i < 1000) {
        wir_declare_struct(ref program, "unused" + i);
        i++;
    }
    if (wir_signed_int_type(ref program, 32) != integer || wir_pointer_type(ref program, integer) != pointer ||
        wir_array_type(ref program, integer, UIntSize(12U)) != array ||
        wir_function_type(ref program, [integer, pointer], integer, false, WirABI.White) != signature) {
        print("FAIL: arena growth changed canonical type identity");
        return 1;
    }
    wir_add_type(ref program, program.arena.types[wir_id_index(UInt32(signature))]);
    wir_add_type(ref program, program.arena.types[wir_id_index(UInt32(array))]);
    if (wir_array_type(ref program, integer, UIntSize(12U)) != array ||
        wir_function_type(ref program, [integer, pointer], integer, false, WirABI.White) != signature) {
        print("FAIL: duplicate type insertion replaced the canonical ID");
        return 1;
    }
    let other: WirTypeID = wir_function_type(ref program, [pointer, integer], integer, true, WirABI.C);
    let key = wir_signature_key([integer, pointer], integer, false, WirABI.White);
    let head = program.arena.shape_heads.lookup(key);
    let link = program.arena.shape_links[wir_id_index(UInt32(other))];
    // force a collision, matching still needs parameter order, ABI and variadic state.
    program.arena.shape_links[wir_id_index(UInt32(other))] = head;
    program.arena.shape_heads.put(key, other);
    if (wir_function_type(ref program, [integer, pointer], integer, false, WirABI.White) != signature) {
        print("FAIL: a signature hash collision changed the function type");
        return 1;
    }
    program.arena.shape_heads.put(key, head);
    program.arena.shape_links[wir_id_index(UInt32(other))] = link;
    if (wir_array_type(ref program, integer, UIntSize(13U)) == array ||
        wir_function_type(ref program, [integer, pointer], integer, true, WirABI.White) == signature ||
        wir_function_type(ref program, [integer, pointer], integer, false, WirABI.C) == signature) {
        print("FAIL: distinct aggregate or function types share an ID");
        return 1;
    }
    let first: WirFuncID = wir_add_function(ref program, "duplicate", [], program.void_type, false, WirLinkage.Internal, WirABI.White);
    wir_add_function(ref program, "duplicate", [], program.void_type, false, WirLinkage.Internal, WirABI.White);
    if (program.arena.function_names.lookup("duplicate") != first || program.arena.functions.length() != 2) {
        print("FAIL: function index hid a duplicate declaration");
        return 1;
    }
    print("PASS: WIR type caches");
    return 0;
}
