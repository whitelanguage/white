// compiler/wir/lowering/types.wl
import * from "../model.wl"
import * from "../builder.wl"
import * from "../../context.wl"
import PARAM_VALUE, PARAM_REF from "../../../frontend/ast.wl"

struct WirTypeMap(
    cache: Vector(WirTypeID),
    errors: Vector(String),
    opaque_pointer: WirTypeID,
    string_type: WirTypeID,
    error_type: WirTypeID
)

func new_wir_type_map() -> WirTypeMap {
    return WirTypeMap(cache=[], errors=[], opaque_pointer=NO_WIR_TYPE, string_type=NO_WIR_TYPE, error_type=NO_WIR_TYPE);
}

func wir_prepare_type_slot(ref types: WirTypeMap, source_type: Int) -> Void {
    while (types.cache.length() <= source_type) { types.cache.append(NO_WIR_TYPE); }
}

func wir_cached_type(ref types: WirTypeMap, source_type: Int) -> WirTypeID {
    if (source_type < 0 || source_type >= types.cache.length()) { return NO_WIR_TYPE; }
    return types.cache[source_type];
}

func wir_cache_type(ref types: WirTypeMap, source_type: Int, type_id: WirTypeID) -> WirTypeID {
    wir_prepare_type_slot(ref types, source_type);
    types.cache[source_type] = type_id;
    return type_id;
}

func wir_type_failure(ref types: WirTypeMap, source_type: Int) -> WirTypeID {
    types.errors.append("Cannot lower White type id " + source_type + " to WIR");
    return NO_WIR_TYPE;
}

func wir_opaque_pointer(ref types: WirTypeMap, ref program: WirModule) -> WirTypeID {
    if (types.opaque_pointer == NO_WIR_TYPE) { types.opaque_pointer = wir_pointer_type(ref program, program.void_type); }
    return types.opaque_pointer;
}

func wir_lower_callable_type(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, source_type: Int, signature: SymbolInfo) -> WirTypeID {
    let result: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, signature.type);
    if (result == NO_WIR_TYPE) { return NO_WIR_TYPE; }

    let parameters: Vector(WirTypeID) = [];
    let i: Int = 0;
    while (signature.func_arg_types is !null && i < signature.func_arg_types.length()) {
        let parameter: TypeListNode = signature.func_arg_types[i];
        let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, parameter.type);
        if (type_id == NO_WIR_TYPE) { return NO_WIR_TYPE; }
        if (parameter.pass_mode == PARAM_REF) {
            type_id = wir_pointer_type(ref program, type_id);
        } else if (parameter.pass_mode != PARAM_VALUE) {
            types.errors.append("Unknown parameter passing mode " + parameter.pass_mode + " in callable type " + source_type);
            return NO_WIR_TYPE;
        }
        parameters.append(type_id);
        i++;
    }
    return wir_function_type(ref program, parameters, result, false);
}

func wir_string_layout(ref types: WirTypeMap, ref program: WirModule) -> WirTypeID {
    if (types.string_type != NO_WIR_TYPE) { return types.string_type; }
    let record: WirTypeID = wir_declare_struct(ref program, "$String");
    let byte: WirTypeID = wir_unsigned_int_type(ref program, 8);
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    wir_define_struct(ref program, record, [wir_pointer_type(ref program, byte), int_type, int_type]);
    types.string_type = wir_pointer_type(ref program, record);
    return types.string_type;
}

func wir_error_layout(ref types: WirTypeMap, ref program: WirModule) -> WirTypeID {
    if (types.error_type != NO_WIR_TYPE) { return types.error_type; }
    let record: WirTypeID = wir_declare_struct(ref program, "$Error");
    wir_define_struct(ref program, record, [wir_unsigned_int_type(ref program, 64), wir_signed_int_type(ref program, 32)]);
    types.error_type = record;
    return record;
}

func wir_lower_struct_type(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, source_type: Int, info: StructInfo) -> WirTypeID {
    if (info.is_enum) { return wir_cache_type(ref types, source_type, wir_signed_int_type(ref program, 32)); }

    let record: WirTypeID = wir_declare_struct(ref program, info.name);
    let result: WirTypeID = record;
    if (info.is_class) { result = wir_pointer_type(ref program, record); }
    wir_cache_type(ref types, source_type, result);

    let fields: Vector(WirTypeID) = [];
    if (info.is_interface) {
        let pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
        fields.append(pointer);
        fields.append(pointer);
    } else {
        let i: Int = 0;
        while (info.fields is !null && i < info.fields.length()) {
            let field: FieldInfo = info.fields[i];
            let field_type: WirTypeID = NO_WIR_TYPE;
            if (field.name == "_vptr" && field.type == TYPE_VOID) {
                field_type = wir_opaque_pointer(ref types, ref program);
            } else {
                field_type = wir_lower_source_type(ref types, ref source, ref program, field.type);
            }
            if (field_type == NO_WIR_TYPE) { return result; }
            fields.append(field_type);
            i++;
        }
        if (fields.length() == 0) { fields.append(wir_unsigned_int_type(ref program, 8)); }
    }
    wir_define_struct(ref program, record, fields);
    return result;
}

func wir_lower_array_type(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, source_type: Int, info: ArrayInfo) -> WirTypeID {
    let element: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, info.base_type);
    if (element == NO_WIR_TYPE) { return NO_WIR_TYPE; }
    if (info.size >= 0) { return wir_cache_type(ref types, source_type, wir_array_type(ref program, element, UIntSize(info.size))); }

    let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
    let pointer: WirTypeID = wir_pointer_type(ref program, element);
    let fields: Vector(WirTypeID) = [size_type, size_type, wir_opaque_pointer(ref types, ref program), wir_pointer_type(ref program, pointer), wir_pointer_type(ref program, size_type)];
    return wir_cache_type(ref types, source_type, wir_struct_type(ref program, fields));
}

func wir_lower_source_type(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, source_type: Int) -> WirTypeID {
    if (source_type <= 0) { return wir_type_failure(ref types, source_type); }
    let cached: WirTypeID = wir_cached_type(ref types, source_type);
    if (cached != NO_WIR_TYPE) { return cached; }

    let result: WirTypeID = NO_WIR_TYPE;
    if (source_type == TYPE_VOID) { result = program.void_type; }
    else if (source_type == TYPE_BOOL) { result = program.bool_type; }
    else if (source_type == TYPE_BYTE) { result = wir_unsigned_int_type(ref program, 8); }
    else if (source_type == TYPE_INT8) { result = wir_signed_int_type(ref program, 8); }
    else if (source_type == TYPE_INT16) { result = wir_signed_int_type(ref program, 16); }
    else if (source_type == TYPE_INT) { result = wir_signed_int_type(ref program, 32); }
    else if (source_type == TYPE_LONG) { result = wir_signed_int_type(ref program, 64); }
    else if (source_type == TYPE_INT128) { result = wir_signed_int_type(ref program, 128); }
    else if (source_type == TYPE_UINT16) { result = wir_unsigned_int_type(ref program, 16); }
    else if (source_type == TYPE_UINT32 || source_type == TYPE_CHAR) { result = wir_unsigned_int_type(ref program, 32); }
    else if (source_type == TYPE_UINT64) { result = wir_unsigned_int_type(ref program, 64); }
    else if (source_type == TYPE_UINT128) { result = wir_unsigned_int_type(ref program, 128); }
    else if (source_type == TYPE_INTSIZE) { result = wir_signed_int_type(ref program, program.pointer_bits); }
    else if (source_type == TYPE_UINTSIZE) { result = wir_unsigned_int_type(ref program, program.pointer_bits); }
    else if (source_type == TYPE_FLOAT32) { result = wir_float_type(ref program, 32); }
    else if (source_type == TYPE_FLOAT) { result = wir_float_type(ref program, 64); }
    else if (source_type == TYPE_STRING) { result = wir_string_layout(ref types, ref program); }
    else if (source_type == TYPE_ANY_ERROR) { result = wir_error_layout(ref types, ref program); }
    else if (source_type == TYPE_ANYPTR || source_type == TYPE_NULLPTR || source_type == TYPE_NULL) { result = wir_opaque_pointer(ref types, ref program); }
    else if (source_type == TYPE_GENERIC_ENUM) { result = wir_signed_int_type(ref program, 32); }
    else if (source_type == TYPE_GENERIC_STRUCT || source_type == TYPE_GENERIC_CLASS || source_type == TYPE_GENERIC_FUNCTION || source_type == TYPE_GENERIC_METHOD) { result = wir_opaque_pointer(ref types, ref program); }
    if (result != NO_WIR_TYPE) { return wir_cache_type(ref types, source_type, result); }

    let key: String = "" + source_type;
    if (source.named_type_ids is !null) {
        let named: NamedTypeInfo = source.named_type_ids.lookup(key);
        if (has_named_type(named)) {
            result = wir_lower_source_type(ref types, ref source, ref program, named.underlying_type);
            if (result != NO_WIR_TYPE) { return wir_cache_type(ref types, source_type, result); }
            return NO_WIR_TYPE;
        }
    }
    if (source.ptr_base_map is !null) {
        let pointer: SymbolInfo = source.ptr_base_map.lookup(key);
        if (has_symbol(pointer)) {
            let element: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, pointer.type);
            if (element == NO_WIR_TYPE) { return NO_WIR_TYPE; }
            return wir_cache_type(ref types, source_type, wir_pointer_type(ref program, element));
        }
    }
    if (source.array_info_map is !null) {
        let array: ArrayInfo = source.array_info_map.lookup(key);
        if (has_array_info(array)) { return wir_lower_array_type(ref types, ref source, ref program, source_type, array); }
    }
    if (source.vector_base_map is !null) {
        let vector: SymbolInfo = source.vector_base_map.lookup(key);
        if (has_symbol(vector)) {
            let element: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, vector.type);
            if (element == NO_WIR_TYPE) { return NO_WIR_TYPE; }
            let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
            let record: WirTypeID = wir_struct_type(ref program, [size_type, size_type, wir_pointer_type(ref program, element)]);
            return wir_cache_type(ref types, source_type, wir_pointer_type(ref program, record));
        }
    }
    if (source.fallible_base_map is !null) {
        let fallible: SymbolInfo = source.fallible_base_map.lookup(key);
        if (has_symbol(fallible)) {
            let fields: Vector(WirTypeID) = [program.bool_type, wir_error_layout(ref types, ref program)];
            if (fallible.type != TYPE_VOID) {
                let value: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, fallible.type);
                if (value == NO_WIR_TYPE) { return NO_WIR_TYPE; }
                fields.append(value);
            }
            return wir_cache_type(ref types, source_type, wir_struct_type(ref program, fields));
        }
    }
    if (source.func_ret_map is !null) {
        let function: SymbolInfo = source.func_ret_map.lookup(key);
        if (has_symbol(function)) {
            return wir_cache_type(ref types, source_type, wir_lower_callable_type(ref types, ref source, ref program, source_type, function));
        }
    }
    if (source.method_ret_map is !null && has_symbol(source.method_ret_map.lookup(key))) {
        return wir_cache_type(ref types, source_type, wir_opaque_pointer(ref types, ref program));
    }
    if (source.struct_id_map is !null) {
        let info: StructInfo = source.struct_id_map.lookup(key);
        if (has_struct(info)) { return wir_lower_struct_type(ref types, ref source, ref program, source_type, info); }
    }
    if (source_type == TYPE_AUTO || source_type == TYPE_POISON) { return wir_type_failure(ref types, source_type); }
    return wir_type_failure(ref types, source_type);
}
