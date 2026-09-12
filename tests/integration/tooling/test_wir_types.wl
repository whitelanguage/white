// Test: WIR_TYPE_LOWERING
// File: tests/integration/tooling/test_wir_types.wl
// Focus: Mapping resolved White types to target-specific WIR layouts.

import * from "../../../src/compiler/context.wl"
import PARAM_VALUE from "../../../src/frontend/ast.wl"
import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/verify.wl"
import * from "../../../src/compiler/wir/lowering/types.wl"

func type_kind(program: WirModule, type_id: WirTypeID) -> WirTypeKind {
    return program.arena.types[wir_id_index(UInt32(type_id))].kind;
}

func main() -> Int {
    let source: Compiler = Compiler(
        ptr_base_map=Dict(),
        vector_base_map=Dict(),
        array_info_map=Dict(),
        fallible_base_map=Dict(),
        func_ret_map=Dict(),
        method_ret_map=Dict(),
        struct_id_map=Dict(),
        named_type_ids=Dict()
    );

    source.ptr_base_map.put("100", SymbolInfo(reg="", type=TYPE_INT));
    source.array_info_map.put("101", ArrayInfo(base_type=TYPE_INT, size=4, llvm_name=""));
    source.vector_base_map.put("102", SymbolInfo(reg="", type=TYPE_CHAR));

    let point_fields: Vector(Struct) = [];
    point_fields.append(FieldInfo(name="x", type=TYPE_INT, llvm_type="", offset=0, is_const=false));
    point_fields.append(FieldInfo(name="y", type=TYPE_INT, llvm_type="", offset=1, is_const=false));
    source.struct_id_map.put("103", StructInfo(name="Point", type_id=103, fields=point_fields, is_class=false, is_enum=false, is_interface=false));

    let class_fields: Vector(Struct) = [];
    class_fields.append(FieldInfo(name="_vptr", type=TYPE_VOID, llvm_type="", offset=0, is_const=true));
    class_fields.append(FieldInfo(name="value", type=TYPE_INT, llvm_type="", offset=1, is_const=false));
    source.struct_id_map.put("104", StructInfo(name="Box", type_id=104, fields=class_fields, is_class=true, is_enum=false, is_interface=false));
    source.named_type_ids.put("105", NamedTypeInfo(name="NodeID", type_id=105, underlying_type=TYPE_UINT32, is_alias=false, resolved=true));
    source.array_info_map.put("106", ArrayInfo(base_type=TYPE_BYTE, size=-1, llvm_name="slice"));
    source.fallible_base_map.put("107", SymbolInfo(reg="", type=TYPE_INT));
    source.func_ret_map.put("108", SymbolInfo(reg="", type=TYPE_INT, func_arg_types=[TypeListNode(type=TYPE_INT, pass_mode=PARAM_VALUE)]));

    let program: WirModule = new_wir_module("i686-pc-windows-msvc", 32);
    let types: WirTypeMap = new_wir_type_map();
    let size_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, TYPE_INTSIZE);
    if (type_kind(program, size_type) != WirTypeKind.SignedInt || program.arena.types[wir_id_index(UInt32(size_type))].bits != 32) {
        print("FAIL: IntSize ignored the WIR target pointer width");
        return 1;
    }

    let pointer: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, 100);
    if (type_kind(program, pointer) != WirTypeKind.Pointer) {
        print("FAIL: pointer type was not lowered as a pointer");
        return 1;
    }
    let array: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, 101);
    if (type_kind(program, array) != WirTypeKind.Array || program.arena.types[wir_id_index(UInt32(array))].length != UIntSize(4U)) {
        print("FAIL: fixed array layout was not preserved");
        return 1;
    }
    let vector: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, 102);
    if (type_kind(program, vector) != WirTypeKind.Pointer) {
        print("FAIL: Vector was not lowered to its reference representation");
        return 1;
    }
    let point: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, 103);
    if (type_kind(program, point) != WirTypeKind.Struct) {
        print("FAIL: value struct was not kept by value");
        return 1;
    }
    let box: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, 104);
    if (type_kind(program, box) != WirTypeKind.Pointer) {
        print("FAIL: class was not lowered to a reference");
        return 1;
    }
    let named: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, 105);
    if (named != wir_lower_source_type(ref types, ref source, ref program, TYPE_UINT32)) {
        print("FAIL: named type did not use its resolved representation");
        return 1;
    }
    let slice: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, 106);
    let slice_pointer: WirType = program.arena.types[wir_id_index(UInt32(slice))];
    if (slice_pointer.kind != WirTypeKind.Pointer || type_kind(program, slice_pointer.element) != WirTypeKind.Struct) {
        print("FAIL: slice did not use its reference representation");
        return 1;
    }
    if (type_kind(program, wir_lower_source_type(ref types, ref source, ref program, 107)) != WirTypeKind.Struct) {
        print("FAIL: fallible value layout was not lowered");
        return 1;
    }
    let function_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, 108);
    let function_layout: WirType = program.arena.types[wir_id_index(UInt32(function_type))];
    if (function_layout.kind != WirTypeKind.Pointer || function_layout.element != program.void_type) {
        print("FAIL: first-class function did not use the callable object representation");
        return 1;
    }
    wir_lower_source_type(ref types, ref source, ref program, TYPE_STRING);

    let errors: Vector(String) = verify_wir(program);
    if (types.errors.length() != 0 || errors.length() != 0) {
        print("FAIL: valid White type layouts produced invalid WIR");
        return 1;
    }

    print("PASS: WIR type lowering");
    return 0;
}
