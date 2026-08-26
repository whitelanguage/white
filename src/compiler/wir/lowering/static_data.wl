// compiler/wir/lowering/static_data.wl

import * from "../model.wl"
import * from "../builder.wl"
import * from "../runtime.wl"
import * from "types.wl"
import * from "../../context.wl"
import * from "../../constants.wl"
import * from "../../../frontend/ast.wl"
import * from "../../../frontend/arena.wl"
import Position from "../../../frontend/diagnostics.wl"

func wir_truncate_integer(value: UInt128, bits: Int) -> UInt128 {
    if (bits >= 128) { return value; }
    let limit: UInt128 = UInt128(1U) << UInt128(bits);
    return value & (limit - UInt128(1U));
}

func wir_lower_string_constant(ref types: WirTypeMap, ref program: WirModule, value: String) -> WirValueID {
    let existing: WirValueID = types.string_values.lookup(value);
    if (existing != NO_WIR_VALUE) { return existing; }

    let id: Int = types.string_count;
    types.string_count++;
    let name: String = ".str." + id;
    let bytes_name: String = name + ".bytes";
    let byte_type: WirTypeID = wir_unsigned_int_type(ref program, 8);
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let bytes_type: WirTypeID = wir_array_type(ref program, byte_type, UIntSize(value.length() + 1));
    let bytes: WirValueID = wir_const_bytes(ref program, bytes_type, value + '\0');
    let bytes_global: WirGlobalID = wir_add_aligned_global(ref program, bytes_name, bytes_type, bytes, WirLinkage.Private, true, 1);
    let data: WirValueID = wir_const_address(ref program, wir_pointer_type(ref program, byte_type), wir_global_value(program, bytes_global), 0L);
    let length: WirValueID = wir_const_int(ref program, int_type, UInt128(UInt32(value.length())));
    let string: WirValueID = wir_const_aggregate(ref program, wir_string_record(ref types, ref program), [data, length, length]);
    let ref_count: WirValueID = wir_const_int(ref program, int_type, UInt128(WIR_STATIC_REFCOUNT));
    let type_id: WirValueID = wir_const_int(ref program, int_type, UInt128(UInt32(TYPE_STRING)));
    let object: WirValueID = wir_const_aggregate(ref program, wir_string_object_layout(ref types, ref program), [ref_count, type_id, string]);
    let object_global: WirGlobalID = wir_add_aligned_global(ref program, name, wir_string_object_layout(ref types, ref program), object, WirLinkage.Private, true, program.data_layout.pointer_alignment);
    let result: WirValueID = wir_const_address(ref program, wir_string_layout(ref types, ref program), wir_global_value(program, object_global), Long(WIR_STRING_HEADER_SIZE));
    types.string_values.put(value, result);
    return result;
}

func wir_static_array(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: NodeID, source_type: Int, pos: Position) -> WirValueID {
    let repr: Int = get_repr_type(ref source, source_type);
    let info: ArrayInfo = source.array_info_map.lookup("" + repr);
    if (!has_array_info(info) || info.size < 0 || node_tag(node) != NODE_VECTOR_LIT) { return NO_WIR_VALUE; }

    let literal: VectorLitNode = get_vector_lit_node(source.arena, node);
    let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
    if (literal.elements.length() == 0) { return wir_const_zero(ref program, type_id); }
    if (literal.elements.length() != info.size) {
        types.errors.append("Partially initialized static arrays are not supported by WIR yet");
        return NO_WIR_VALUE;
    }
    let elements: Vector(WirValueID) = [];
    let i: Int = 0;
    while (i < literal.elements.length()) {
        let argument: ArgNode = literal.elements[i];
        if ((argument.name is !null && argument.name.length() != 0) || argument.is_spread) {
            types.errors.append("Static array initializer contains a named or spread element");
            return NO_WIR_VALUE;
        }
        let value: WirValueID = wir_lower_static_value(ref types, ref source, ref program, argument.val, info.base_type, pos);
        if (value == NO_WIR_VALUE) { return NO_WIR_VALUE; }
        elements.append(value);
        i++;
    }
    return wir_const_aggregate(ref program, type_id, elements);
}

func wir_static_struct(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: NodeID, source_type: Int, pos: Position) -> WirValueID {
    if (node_tag(node) != NODE_CALL || source.struct_id_map is null) { return NO_WIR_VALUE; }
    let info: StructInfo = source.struct_id_map.lookup("" + get_repr_type(ref source, source_type));
    if (!has_struct(info) || info.is_class || info.is_interface ||
        info.is_enum || has_node(info.init_body)) {
        return NO_WIR_VALUE;
    }

    let call: CallNode = get_call_node(source.arena, node);
    let field_count: Int = 0;
    if (info.fields is !null) { field_count = info.fields.length(); }
    let argument_count: Int = 0;
    if (call.args is !null) { argument_count = call.args.length(); }
    if (argument_count != field_count) {
        types.errors.append("Static struct initializer must provide every field");
        return NO_WIR_VALUE;
    }

    let values: Vector(WirValueID) = [];
    let assigned: Vector(Bool) = [];
    let i: Int = 0;
    while (i < field_count) {
        values.append(NO_WIR_VALUE);
        assigned.append(false);
        i++;
    }
    let saw_named: Bool = false;
    i = 0;
    while (i < argument_count) {
        let argument: ArgNode = call.args[i];
        if (argument.is_spread) {
            types.errors.append("Static struct initializer contains a spread argument");
            return NO_WIR_VALUE;
        }
        let field_index: Int = i;
        if (argument.name is !null && argument.name.length() != 0) {
            saw_named = true;
            let field: FieldInfo = find_field(info, argument.name);
            if (!has_field(field)) {
                types.errors.append("Static struct initializer has no field named '" + argument.name + "'");
                return NO_WIR_VALUE;
            }
            field_index = field.offset;
        } else if saw_named {
            types.errors.append("Positional argument follows a named argument in a static struct initializer");
            return NO_WIR_VALUE;
        }
        if (field_index < 0 || field_index >= field_count || assigned[field_index]) {
            types.errors.append("Static struct field is initialized more than once");
            return NO_WIR_VALUE;
        }
        let field: FieldInfo = info.fields[field_index];
        let value: WirValueID = wir_lower_static_value(ref types, ref source, ref program, argument.val, field.type, pos);
        if (value == NO_WIR_VALUE) { return NO_WIR_VALUE; }
        values[field_index] = value;
        assigned[field_index] = true;
        i++;
    }
    let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
    return wir_const_aggregate(ref program, type_id, values);
}

func wir_lower_static_value(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: NodeID, source_type: Int, pos: Position) -> WirValueID {
    if (!has_node(node)) { return NO_WIR_VALUE; }
    let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
    if (type_id == NO_WIR_TYPE) { return NO_WIR_VALUE; }
    let repr: Int = get_repr_type(ref source, source_type);
    let kind: Int = node_tag(node);

    if (kind == NODE_NULLPTR &&
        (is_pointer_type(ref source, source_type) || source_type == TYPE_ANYPTR)) {
        return wir_null(ref program, type_id);
    }
    if (kind == NODE_NULL && !is_pointer_type(ref source, source_type) && is_nullable_reference_type(ref source, source_type)) {
        if (program.arena.types[wir_id_index(UInt32(type_id))].kind == WirTypeKind.Pointer) {
            return wir_null(ref program, type_id);
        }
        return wir_const_zero(ref program, type_id);
    }
    if (repr == TYPE_STRING && kind == NODE_STRING) {
        return wir_lower_string_constant(ref types, ref program, get_string_node(source.arena, node).tok.value);
    }
    if (repr == TYPE_BOOL) { return wir_const_bool(ref program, eval_const_bool(ref source, node, pos) != 0); }
    if (repr == TYPE_CHAR) { return wir_const_int(ref program, type_id, UInt128(eval_const_long(ref source, node, pos))); }
    if (is_integer_type(repr)) {
        let value: UInt128 = eval_const_wide(ref source, node, pos, is_unsigned_integer(repr));
        return wir_const_int(ref program, type_id, wir_truncate_integer(value, get_type_bitwidth(repr)));
    }
    if (repr == TYPE_FLOAT || repr == TYPE_FLOAT32) {
        let value: Float = eval_const_float(ref source, node, pos);
        if (repr == TYPE_FLOAT32) { value = Float(Float32(value)); }
        return wir_const_float(ref program, type_id, value);
    }
    if (source.array_info_map is !null && has_array_info(source.array_info_map.lookup("" + repr))) {
        return wir_static_array(ref types, ref source, ref program, node, source_type, pos);
    }
    if (source.struct_id_map is !null && has_struct(source.struct_id_map.lookup("" + repr))) {
        return wir_static_struct(ref types, ref source, ref program, node, source_type, pos);
    }
    return NO_WIR_VALUE;
}
