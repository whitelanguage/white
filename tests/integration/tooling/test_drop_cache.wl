// Test: DROP_CACHE
// File: tests/integration/tooling/test_drop_cache.wl
// Focus: Invalidating ownership queries when forward declarations gain fields.

import * from "../../../src/compiler/context.wl"
import new_fixture_compiler from "../../fixtures/tooling/compiler.wl"
import NodeID from "../../../src/frontend/ast.wl"
import Position from "../../../src/frontend/diagnostics.wl"


func main() -> Int {
    let source: Compiler = new_fixture_compiler()?;
    catch(err) { return 1; }
    source.type_counter = 104;
    source.type_revision = 0;
    source.drop_cache = [];
    source.struct_table = Dict();
    source.struct_id_map = Dict();
    source.named_types = Dict();
    source.named_type_ids = Dict();
    source.ptr_base_map = Dict();
    source.array_info_map = Dict();
    source.vector_base_map = Dict();
    source.func_ret_map = Dict();
    source.method_ret_map = Dict();
    source.fallible_base_map = Dict();
    let leaf: StructInfo = StructInfo(name="Leaf", type_id=100, fields=[], llvm_name="", init_body=NodeID(0U), is_class=false, vtable_name="", parent_id=0, vtable=[], ann_flags=0, is_enum=false, is_error=false, is_interface=false, interfaces=[], compiler_link_name="", layout_ready=false);
    let parent: StructInfo = StructInfo(name="Parent", type_id=101, fields=[FieldInfo(name="leaf", type=100, llvm_type="", offset=0, is_const=false, default_val=NodeID(0U))], llvm_name="", init_body=NodeID(0U), is_class=false, vtable_name="", parent_id=0, vtable=[], ann_flags=0, is_enum=false, is_error=false, is_interface=false, interfaces=[], compiler_link_name="", layout_ready=false);
    store_struct(ref source, leaf);
    store_struct(ref source, parent);
    if (needs_drop(ref source, 101) || needs_drop(ref source, TYPE_INT)) {
        print("FAIL: plain values acquired ownership");
        return 1;
    }

    leaf.fields = [FieldInfo(name="text", type=TYPE_STRING, llvm_type="", offset=0, is_const=false, default_val=NodeID(0U))];
    store_struct(ref source, leaf);
    if (!needs_drop(ref source, 101) || !needs_drop(ref source, 100)) {
        print("FAIL: completing a field left a stale drop result");
        return 1;
    }

    source.array_info_map.put(102, ArrayInfo(base_type=101, size=2, llvm_name=""));
    source.type_counter++;
    if (!needs_drop(ref source, 102)) {
        print("FAIL: aggregate elements lost ownership");
        return 1;
    }

    leaf.fields = [];
    store_struct(ref source, leaf);
    if (needs_drop(ref source, 102) || needs_drop(ref source, 101)) {
        print("FAIL: dependent entries survived a declaration update");
        return 1;
    }

    store_named_type(ref source, NamedTypeInfo(name="Text", type_id=103, underlying_type=TYPE_STRING, resolved=true, is_alias=false, target_node=NodeID(0U), pos=Position(idx=0, ln=0, col=0, text="", fn=""), resolving=false));
    if (!needs_drop(ref source, 103)) {
        print("FAIL: named reference ownership was lost");
        return 1;
    }

    store_named_type(ref source, NamedTypeInfo(name="Text", type_id=103, underlying_type=TYPE_INT, resolved=true, is_alias=false, target_node=NodeID(0U), pos=Position(idx=0, ln=0, col=0, text="", fn=""), resolving=false));
    if (needs_drop(ref source, 103)) {
        print("FAIL: named representation kept a stale drop result");
        return 1;
    }

    print("PASS: ownership cache follows declaration changes");
    return 0;
}
