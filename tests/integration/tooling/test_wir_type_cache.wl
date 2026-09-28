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
    if (wir_signed_int_type(ref program, 32) != integer || wir_pointer_type(ref program, integer) != pointer) {
        print("FAIL: arena growth changed canonical type identity");
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
