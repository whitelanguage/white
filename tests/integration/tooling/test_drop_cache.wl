// Test: DROP_CACHE
// File: tests/integration/tooling/test_drop_cache.wl
// Focus: Invalidating ownership queries when forward declarations gain fields.

import * from "../../../src/compiler/context.wl"


func main() -> Int {
    let source: Compiler = Compiler(type_counter=104, type_revision=0, drop_cache=[], struct_table=Dict(), struct_id_map=Dict(), named_types=Dict(), named_type_ids=Dict(), ptr_base_map=Dict(), array_info_map=Dict(), vector_base_map=Dict(), func_ret_map=Dict(), method_ret_map=Dict(), fallible_base_map=Dict());
    let leaf: StructInfo = StructInfo(name="Leaf", type_id=100, fields=[]);
    let parent: StructInfo = StructInfo(name="Parent", type_id=101, fields=[FieldInfo(name="leaf", type=100)]);
    store_struct(ref source, leaf);
    store_struct(ref source, parent);
    if (needs_drop(ref source, 101) || needs_drop(ref source, TYPE_INT)) {
        print("FAIL: plain values acquired ownership");
        return 1;
    }

    leaf.fields = [FieldInfo(name="text", type=TYPE_STRING)];
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

    store_named_type(ref source, NamedTypeInfo(name="Text", type_id=103, underlying_type=TYPE_STRING, resolved=true));
    if (!needs_drop(ref source, 103)) {
        print("FAIL: named reference ownership was lost");
        return 1;
    }

    store_named_type(ref source, NamedTypeInfo(name="Text", type_id=103, underlying_type=TYPE_INT, resolved=true));
    if (needs_drop(ref source, 103)) {
        print("FAIL: named representation kept a stale drop result");
        return 1;
    }

    print("PASS: ownership cache follows declaration changes");
    return 0;
}
