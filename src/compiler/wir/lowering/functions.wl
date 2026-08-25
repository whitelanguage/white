// compiler/wir/lowering/functions.wl
import * from "../model.wl"
import * from "../builder.wl"
import * from "../layout.wl"
import * from "../runtime.wl"
import * from "state.wl"
import * from "types.wl"
import * from "ownership.wl"
import * from "static_data.wl"
import * from "declarations.wl"
import * from "globals.wl"
import * from "../../context.wl"
import parse_const_uint128, parse_decimal_float_literal from "../../constants.wl"
import class_has_interface, is_unsuffix_int_literal from "../../validation.wl"
import * from "../../../frontend/ast.wl"
import * from "../../../frontend/arena.wl"
import * from "../../../frontend/tokens.wl"

func wir_find_binding(state: WirFunctionLowering, name: String) -> WirBinding? {
    let i: Int = state.bindings.length() - 1;
    while (i >= 0) {
        if (state.bindings[i].name == name) { return state.bindings[i]; }
        i--;
    }
    throw Error.InvalidData;
}

func wir_name_is_value(state: WirFunctionLowering, source: Compiler, name: String) -> Bool {
    let binding: WirBinding = wir_find_binding(state, name)?;
    catch(err) {
        return has_wir_source_global(wir_source_global(ref source, name));
    }
    return true;
}

func wir_source_function(ref source: Compiler, name: String) -> FuncInfo {
    let info: FuncInfo = source.func_table.lookup(name);
    if (!has_func(info) && source.current_file_func_aliases is !null) {
        let mapped: String = source.current_file_func_aliases.lookup(name);
        if (mapped is !null) { info = source.func_table.lookup(mapped); }
    }
    if (!has_func(info) && source.current_package_prefix.length() != 0) {
        info = source.func_table.lookup(source.current_package_prefix + name);
    }
    return info;
}

func wir_restore_bindings(ref state: WirFunctionLowering, length: Int) -> Void {
    let bindings: Vector(WirBinding) = [];
    let i: Int = 0;
    while (i < length && i < state.bindings.length()) {
        bindings.append(state.bindings[i]);
        i++;
    }
    state.bindings = bindings;
}

func wir_next_block_name(ref state: WirFunctionLowering, prefix: String) -> String {
    let name: String = prefix + state.next_block;
    state.next_block++;
    return name;
}

func wir_numeric_opcode(source_type: Int, token: Int) -> WirOpcode {
    let type: Int = source_type;
    if (token == TOK_PLUS) { return WirOpcode.Add; }
    if (token == TOK_SUB) { return WirOpcode.Subtract; }
    if (token == TOK_MUL) { return WirOpcode.Multiply; }
    if (token == TOK_DIV) {
        if (type == TYPE_FLOAT || type == TYPE_FLOAT32) { return WirOpcode.FloatDivide; }
        if (is_unsigned_integer(type)) { return WirOpcode.UnsignedDivide; }
        return WirOpcode.SignedDivide;
    }
    if (token == TOK_MOD) {
        if (type == TYPE_FLOAT || type == TYPE_FLOAT32) { return WirOpcode.FloatRemainder; }
        if (is_unsigned_integer(type)) { return WirOpcode.UnsignedRemainder; }
        return WirOpcode.SignedRemainder;
    }
    if (token == TOK_BIT_AND) { return WirOpcode.BitAnd; }
    if (token == TOK_BIT_OR) { return WirOpcode.BitOr; }
    if (token == TOK_BIT_XOR) { return WirOpcode.BitXor; }
    if (token == TOK_LSHIFT) { return WirOpcode.ShiftLeft; }
    if (token == TOK_RSHIFT) {
        if (is_unsigned_integer(type)) { return WirOpcode.UnsignedShiftRight; }
        return WirOpcode.SignedShiftRight;
    }
    return WirOpcode.Invalid;
}

func wir_comparison_opcode(source_type: Int, token: Int) -> WirOpcode {
    if (token == TOK_EE) { return WirOpcode.Equal; }
    if (token == TOK_NE) { return WirOpcode.NotEqual; }

    let floating: Bool = source_type == TYPE_FLOAT || source_type == TYPE_FLOAT32;
    if floating {
        if (token == TOK_LT) { return WirOpcode.FloatLess; }
        if (token == TOK_LTE) { return WirOpcode.FloatLessEqual; }
        if (token == TOK_GT) { return WirOpcode.FloatGreater; }
        if (token == TOK_GTE) { return WirOpcode.FloatGreaterEqual; }
        return WirOpcode.Invalid;
    }

    let unsigned: Bool = is_unsigned_integer(source_type) || source_type == TYPE_CHAR;
    if unsigned {
        if (token == TOK_LT) { return WirOpcode.UnsignedLess; }
        if (token == TOK_LTE) { return WirOpcode.UnsignedLessEqual; }
        if (token == TOK_GT) { return WirOpcode.UnsignedGreater; }
        if (token == TOK_GTE) { return WirOpcode.UnsignedGreaterEqual; }
        return WirOpcode.Invalid;
    }
    if (is_signed_integer(source_type)) {
        if (token == TOK_LT) { return WirOpcode.SignedLess; }
        if (token == TOK_LTE) { return WirOpcode.SignedLessEqual; }
        if (token == TOK_GT) { return WirOpcode.SignedGreater; }
        if (token == TOK_GTE) { return WirOpcode.SignedGreaterEqual; }
    }
    return WirOpcode.Invalid;
}

func wir_source_numeric(source_type: Int) -> Bool {
    return is_integer_type(source_type) || source_type == TYPE_FLOAT || source_type == TYPE_FLOAT32 || source_type == TYPE_CHAR;
}

func wir_implicit_numeric_cast(source_type: Int, target_type: Int) -> Bool {
    if (source_type == target_type) { return true; }
    if (is_integer_type(source_type) && is_integer_type(target_type)) {
        let source_bits: Int = get_type_bitwidth(source_type);
        let target_bits: Int = get_type_bitwidth(target_type);
        return source_bits < target_bits && !(is_signed_integer(source_type) && is_unsigned_integer(target_type));
    }
    if (source_type == TYPE_BYTE && target_type == TYPE_CHAR) { return true; }
    if (target_type == TYPE_FLOAT && (source_type == TYPE_INT || source_type == TYPE_LONG || source_type == TYPE_FLOAT32)) { return true; }
    return false;
}

func wir_cast_expr(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirExpr, target_type: Int, implicit: Bool) -> WirExpr {
    if (value.value == NO_WIR_VALUE || value.source_type == target_type) { return value; }
    let source_info: StructInfo = StructInfo();
    let target_info: StructInfo = StructInfo();
    if (source.struct_id_map is !null) {
        source_info = source.struct_id_map.lookup("" + get_repr_type(ref source, value.source_type));
        target_info = source.struct_id_map.lookup("" + get_repr_type(ref source, target_type));
    }
    if (has_struct(source_info) && source_info.is_class && has_struct(target_info) && target_info.is_interface) {
        return wir_lower_interface_value(ref state, ref types, ref source, ref program, value, target_type);
    }
    let source_wir: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, value.source_type);
    let target_wir: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, target_type);
    if (source_wir == NO_WIR_TYPE || target_wir == NO_WIR_TYPE) { return wir_no_expr(); }
    let source_kind: WirTypeKind = program.arena.types[wir_id_index(UInt32(source_wir))].kind;
    let target_kind: WirTypeKind = program.arena.types[wir_id_index(UInt32(target_wir))].kind;
    if (source_kind == WirTypeKind.Pointer && target_kind == WirTypeKind.Pointer) {
        let compatible: Bool = value.source_type == TYPE_NULLPTR ||
                               is_void_ptr(ref source, value.source_type) ||
                               is_void_ptr(ref source, target_type);
        if (implicit && !compatible) {
            state.errors.append("implicit pointer conversion reached WIR lowering without compatible pointer types");
            return wir_no_expr();
        }
        let casted: WirValueID = wir_cast(ref program, state.block, value.value, target_wir, "", no_wir_location());
        if (wir_take_owned(ref state, value.value)) { wir_track_owned(ref state, casted, target_type); }
        return WirExpr(value=casted, source_type=target_type);
    }
    if (!wir_source_numeric(value.source_type) || !wir_source_numeric(target_type)) {
        state.errors.append("Non-numeric conversion from type " + value.source_type + " to type " + target_type + " reached WIR lowering");
        return wir_no_expr();
    }
    if (implicit && !wir_implicit_numeric_cast(value.source_type, target_type)) {
        state.errors.append("implicit conversion from " + get_type_name(ref source, value.source_type) + " to " + get_type_name(ref source, target_type) + " reached WIR lowering");
        return wir_no_expr();
    }
    return WirExpr(value=wir_cast(ref program, state.block, value.value, target_wir, "", no_wir_location()), source_type=target_type);
}

func wir_lvalue_type(state: WirFunctionLowering, source: Compiler, node: NodeID) -> Int {
    if (!has_node(node)) { return TYPE_POISON; }
    let kind: Int = node_tag(node);
    if (kind == NODE_VAR_ACCESS) {
        let access: VarAccessNode = get_var_access_node(source.arena, node);
        let binding: WirBinding = wir_find_binding(state, access.name_tok.value)?;
        catch(err) {
            let global: WirSourceGlobal = wir_source_global(ref source, access.name_tok.value);
            if (has_wir_source_global(global)) { return global.source_type; }
            return TYPE_POISON;
        }
        return binding.source_type;
    }
    if (kind == NODE_FIELD_ACCESS) {
        let access: FieldAccessNode = get_field_access_node(source.arena, node);
        let object_type: Int = get_repr_type(ref source, wir_lvalue_type(state, source, access.obj));
        let info: StructInfo = source.struct_id_map.lookup("" + object_type);
        let field: FieldInfo = find_field(info, access.field_name);
        if (has_field(field)) { return field.type; }
        return TYPE_POISON;
    }
    if (kind == NODE_INDEX_ACCESS) {
        let access: IndexAccessNode = get_index_access_node(source.arena, node);
        let target_type: Int = get_repr_type(ref source, wir_lvalue_type(state, source, access.target));
        let info: ArrayInfo = source.array_info_map.lookup("" + target_type);
        if (has_array_info(info)) { return info.base_type; }
    }
    return TYPE_POISON;
}

func wir_lvalue_const(state: WirFunctionLowering, source: Compiler, node: NodeID) -> Bool {
    if (!has_node(node)) { return false; }
    let kind: Int = node_tag(node);
    if (kind == NODE_VAR_ACCESS) {
        let access: VarAccessNode = get_var_access_node(source.arena, node);
        let binding: WirBinding = wir_find_binding(state, access.name_tok.value)?;
        catch(err) {
            let global: WirSourceGlobal = wir_source_global(ref source, access.name_tok.value);
            return has_wir_source_global(global) && global.is_const;
        }
        return binding.is_const;
    }
    if (kind == NODE_FIELD_ACCESS) {
        let access: FieldAccessNode = get_field_access_node(source.arena, node);
        if (wir_lvalue_const(state, source, access.obj)) { return true; }
        let object_type: Int = get_repr_type(ref source, wir_lvalue_type(state, source, access.obj));
        let info: StructInfo = source.struct_id_map.lookup("" + object_type);
        let field: FieldInfo = find_field(info, access.field_name);
        return has_field(field) && field.is_const;
    }
    if (kind == NODE_INDEX_ACCESS) {
        return wir_lvalue_const(state, source, get_index_access_node(source.arena, node).target);
    }
    return false;
}

func wir_field_const(state: WirFunctionLowering, source: Compiler, object: NodeID, name: String) -> Bool {
    if (wir_lvalue_const(state, source, object)) { return true; }
    let object_type: Int = get_repr_type(ref source, wir_lvalue_type(state, source, object));
    let info: StructInfo = source.struct_id_map.lookup("" + object_type);
    let field: FieldInfo = find_field(info, name);
    return has_field(field) && field.is_const;
}

func wir_lower_field_lvalue(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, object_node: NodeID, name: String) -> WirExpr {
    let object_type: Int = get_repr_type(ref source, wir_lvalue_type(state, source, object_node));
    let info: StructInfo = source.struct_id_map.lookup("" + object_type);
    let field: FieldInfo = find_field(info, name);
    if (!has_struct(info) || info.is_interface || !has_field(field)) {
        state.errors.append("field '" + name + "' is not addressable in WIR lowering");
        return wir_no_expr();
    }

    let object: WirExpr = wir_no_expr();
    if (info.is_class) {
        object = wir_lower_expr(ref state, ref types, ref source, ref program, object_node);
        if (object.value == NO_WIR_VALUE) { return wir_no_expr(); }
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [object.value], [], no_wir_location());
    } else {
        object = wir_lower_lvalue(ref state, ref types, ref source, ref program, object_node);
        if (object.value == NO_WIR_VALUE) { return wir_no_expr(); }
    }
    return WirExpr(value=wir_field_address(ref program, state.block, object.value, field.offset, "", no_wir_location()), source_type=field.type);
}

func wir_lower_index_lvalue(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, target_node: NodeID, index_node: NodeID) -> WirExpr {
    let target: WirExpr = wir_lower_lvalue(ref state, ref types, ref source, ref program, target_node);
    if (target.value == NO_WIR_VALUE) { return wir_no_expr(); }
    let target_type: Int = get_repr_type(ref source, target.source_type);
    let info: ArrayInfo = source.array_info_map.lookup("" + target_type);
    if (!has_array_info(info) || info.size < 0) {
        state.errors.append("only fixed arrays have addressable WIR index operations at this stage");
        return wir_no_expr();
    }
    let index: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, index_node);
    if (index.value == NO_WIR_VALUE) { return wir_no_expr(); }
    if (index.source_type != TYPE_INT) {
        state.errors.append("array index reached WIR lowering with a non-Int type");
        return wir_no_expr();
    }
    let length: WirValueID = wir_const_int(ref program, wir_lower_source_type(ref types, ref source, ref program, TYPE_INT), UInt128(UInt32(info.size)));
    wir_append(ref program, state.block, WirOpcode.BoundsCheck, program.void_type, [index.value, length], [], no_wir_location());
    return WirExpr(value=wir_index_address(ref program, state.block, target.value, index.value, "", no_wir_location()), source_type=info.base_type);
}

func wir_lower_lvalue(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: NodeID) -> WirExpr {
    if (!has_node(node)) {
        state.errors.append("missing lvalue reached WIR lowering");
        return wir_no_expr();
    }

    let kind: Int = node_tag(node);
    if (kind == NODE_VAR_ACCESS) {
        let access: VarAccessNode = get_var_access_node(source.arena, node);
        let binding: WirBinding = wir_find_binding(state, access.name_tok.value)?;
        catch(err) {
            let global: WirSourceGlobal = wir_source_global(ref source, access.name_tok.value);
            let global_id: WirGlobalID = NO_WIR_GLOBAL;
            if (has_wir_source_global(global)) { global_id = wir_find_global(program, global.name); }
            if (global_id == NO_WIR_GLOBAL) {
                state.errors.append("unknown value '" + access.name_tok.value + "' in WIR lvalue lowering");
                return wir_no_expr();
            }
            return WirExpr(value=wir_global_value(program, global_id), source_type=global.source_type);
        }
        return WirExpr(value=binding.address, source_type=binding.source_type);
    }

    if (kind == NODE_FIELD_ACCESS) {
        let access: FieldAccessNode = get_field_access_node(source.arena, node);
        return wir_lower_field_lvalue(ref state, ref types, ref source, ref program, access.obj, access.field_name);
    }

    if (kind == NODE_INDEX_ACCESS) {
        let access: IndexAccessNode = get_index_access_node(source.arena, node);
        return wir_lower_index_lvalue(ref state, ref types, ref source, ref program, access.target, access.index_node);
    }

    state.errors.append("expression is not an addressable WIR value");
    return wir_no_expr();
}

func wir_lower_address(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: NodeID) -> WirExpr {
    if (!has_node(node) || node_tag(node) != NODE_REF) {
        state.errors.append("reference parameter reached WIR lowering without 'ref'");
        return wir_no_expr();
    }
    let reference: RefNode = get_ref_node(source.arena, node);
    if (wir_lvalue_const(state, source, reference.node)) {
        state.errors.append("const value reached WIR lowering as a mutable reference");
        return wir_no_expr();
    }
    return wir_lower_lvalue(ref state, ref types, ref source, ref program, reference.node);
}

func wir_struct_constructor(ref source: Compiler, node: NodeID) -> StructInfo {
    if (!has_node(node) || node_tag(node) != NODE_VAR_ACCESS || source.struct_table is null) { return StructInfo(); }
    let access: VarAccessNode = get_var_access_node(source.arena, node);
    let info: StructInfo = source.struct_table.lookup(access.name_tok.value);
    if (!has_struct(info) && source.current_package_prefix.length() != 0) { info = source.struct_table.lookup(source.current_package_prefix + access.name_tok.value); }
    return info;
}

func wir_lower_array_literal(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: NodeID, expected_type: Int) -> WirExpr {
    let source_type: Int = get_repr_type(ref source, expected_type);
    let info: ArrayInfo = source.array_info_map.lookup("" + source_type);
    if (!has_array_info(info) || info.size < 0) {
        state.errors.append("array literal reached WIR lowering without a fixed-array target type");
        return wir_no_expr();
    }

    let literal: VectorLitNode = get_vector_lit_node(source.arena, node);
    if (literal.elements.length() > info.size) {
        state.errors.append("array literal has more elements than its target type in WIR lowering");
        return wir_no_expr();
    }
    let elements: Vector(WirValueID) = [];
    let i: Int = 0;
    while (i < literal.elements.length()) {
        let argument: ArgNode = literal.elements[i];
        if (argument.name.length() != 0 || argument.is_spread) {
            state.errors.append("array literal contains a named or spread element in WIR lowering");
            return wir_no_expr();
        }
        let element: WirExpr = wir_lower_expected_expr(ref state, ref types, ref source, ref program, argument.val, info.base_type);
        if (element.value == NO_WIR_VALUE) { return wir_no_expr(); }
        element = wir_cast_expr(ref state, ref types, ref source, ref program, element, info.base_type, true);
        if (element.value == NO_WIR_VALUE) { return wir_no_expr(); }
        wir_move_or_retain(ref state, ref source, ref program, element);
        elements.append(element.value);
        i++;
    }
    let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, expected_type);
    let result: WirValueID = wir_array_value(ref program, state.block, type_id, elements, "", no_wir_location());
    if (wir_value_needs_drop(ref source, expected_type)) { wir_track_owned(ref state, result, expected_type); }
    return WirExpr(value=result, source_type=expected_type);
}

func wir_lower_struct_constructor(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, call: CallNode, info: StructInfo) -> WirExpr {
    if (info.is_class || info.is_interface || info.is_enum) { return wir_no_expr(); }
    if (has_node(info.init_body)) {
        state.errors.append("struct constructors with an init body are not lowered to WIR yet");
        return wir_no_expr();
    }

    let field_count: Int = 0;
    if (info.fields is !null) { field_count = info.fields.length(); }
    let arguments: Vector(ArgNode) = call.args;
    let argument_count: Int = 0;
    if (arguments is !null) { argument_count = arguments.length(); }
    if (argument_count > field_count) {
        state.errors.append("struct constructor has too many arguments in WIR lowering");
        return wir_no_expr();
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
        let argument: ArgNode = arguments[i];
        if (argument.is_spread) {
            state.errors.append("struct constructor contains a spread argument in WIR lowering");
            return wir_no_expr();
        }
        let field_index: Int = i;
        if (argument.name.length() != 0) {
            saw_named = true;
            let field: FieldInfo = find_field(info, argument.name);
            if (!has_field(field)) {
                state.errors.append("unknown field '" + argument.name + "' in WIR struct construction");
                return wir_no_expr();
            }
            field_index = field.offset;
        } else if saw_named {
            state.errors.append("positional struct argument follows a named argument in WIR lowering");
            return wir_no_expr();
        }
        if (field_index < 0 || field_index >= field_count || assigned[field_index]) {
            state.errors.append("struct field is initialized more than once in WIR lowering");
            return wir_no_expr();
        }
        let field: FieldInfo = info.fields[field_index];
        let value: WirExpr = wir_lower_expected_expr(ref state, ref types, ref source, ref program, argument.val, field.type);
        if (value.value == NO_WIR_VALUE) { return wir_no_expr(); }
        value = wir_cast_expr(ref state, ref types, ref source, ref program, value, field.type, true);
        if (value.value == NO_WIR_VALUE) { return wir_no_expr(); }
        wir_move_or_retain(ref state, ref source, ref program, value);
        values[field_index] = value.value;
        assigned[field_index] = true;
        i++;
    }

    let last: Int = -1;
    i = 0;
    while (i < field_count) {
        if (assigned[i]) { last = i; }
        i++;
    }
    i = 0;
    while (i <= last) {
        if (!assigned[i]) {
            state.errors.append("named struct construction leaves a field gap that WIR cannot represent yet");
            return wir_no_expr();
        }
        i++;
    }
    let operands: Vector(WirValueID) = [];
    i = 0;
    while (i <= last) {
        operands.append(values[i]);
        i++;
    }
    let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, info.type_id);
    let result: WirValueID = wir_struct_value(ref program, state.block, type_id, operands, "", no_wir_location());
    if (wir_value_needs_drop(ref source, info.type_id)) { wir_track_owned(ref state, result, info.type_id); }
    return WirExpr(value=result, source_type=info.type_id);
}

func wir_pointer_offset(ref program: WirModule, block: WirBlockID, pointer: WirValueID, offset: Int, target_type: WirTypeID) -> WirValueID {
    let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
    let address: WirValueID = wir_cast(ref program, block, pointer, size_type, "", no_wir_location());
    let amount: WirValueID = wir_const_int(ref program, size_type, UInt128(UIntSize(offset)));
    let adjusted: WirValueID = wir_binary(ref program, block, WirOpcode.Add, size_type, address, amount, "", no_wir_location());
    return wir_cast(ref program, block, adjusted, target_type, "", no_wir_location());
}

func wir_class_drop_name(info: StructInfo) -> String {
    return "__wl_drop." + info.type_id;
}

func wir_class_drop_function(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, info: StructInfo) -> WirFuncID {
    let name: String = wir_class_drop_name(info);
    let function_id: WirFuncID = wir_find_function(program, name);
    if (function_id != NO_WIR_FUNC) { return function_id; }

    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    function_id = wir_add_function(ref program, name, [wir_param("object", raw_pointer)], program.void_type, false, WirLinkage.Internal, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let object: WirValueID = wir_cast(ref program, entry, function.parameters[0], wir_lower_source_type(ref types, ref source, ref program, info.type_id), "", no_wir_location());
    let state: WirFunctionLowering = WirFunctionLowering(function=function_id, return_type=TYPE_VOID, entry=entry, block=entry, bindings=[], loops=[], owned_values=[], errors=[], terminated=false, next_block=0);

    let deinit: FuncInfo = source.func_table.lookup(info.name + "_$deinit");
    if (has_func(deinit)) {
        let deinit_id: WirFuncID = wir_find_function(program, deinit.name);
        if (deinit_id == NO_WIR_FUNC) { deinit_id = wir_lower_function_decl(ref types, ref source, ref program, deinit); }
        if (deinit_id != NO_WIR_FUNC) { wir_call(ref program, entry, wir_function_value(program, deinit_id), [object], "", no_wir_location()); }
    }

    let i: Int = 0;
    while (info.fields is !null && i < info.fields.length()) {
        let field: FieldInfo = info.fields[i];
        if (field.name != "_vptr" && wir_value_needs_drop(ref source, field.type)) {
            let address: WirValueID = wir_field_address(ref program, entry, object, field.offset, "", no_wir_location());
            wir_emit_ownership_slot(ref state, ref source, ref program, address, field.type, false);
        }
        i++;
    }
    i = 0;
    while (i < state.errors.length()) {
        types.errors.append(state.errors[i]);
        i++;
    }
    wir_return(ref program, entry, NO_WIR_VALUE, no_wir_location());
    return function_id;
}

func wir_call_class_field_initializers(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, info: StructInfo, object: WirValueID) -> Void {
    if (info.parent_id != 0) {
        let parent: StructInfo = source.struct_id_map.lookup("" + info.parent_id);
        if (has_struct(parent)) { wir_call_class_field_initializers(ref state, ref types, ref source, ref program, parent, object); }
    }

    let initializer: FuncInfo = source.func_table.lookup(info.name + "_$field_init");
    if (!has_func(initializer)) { return; }
    let function_id: WirFuncID = wir_find_function(program, initializer.name);
    if (function_id == NO_WIR_FUNC) { function_id = wir_lower_function_decl(ref types, ref source, ref program, initializer); }
    if (function_id == NO_WIR_FUNC) { return; }
    let self_type: WirTypeID = program.arena.types[wir_id_index(UInt32(program.arena.functions[wir_id_index(UInt32(function_id))].type_id))].parameters[0];
    let self: WirValueID = object;
    if (wir_value_type(program, self) != self_type) { self = wir_cast(ref program, state.block, self, self_type, "", no_wir_location()); }
    wir_call(ref program, state.block, wir_function_value(program, function_id), [self], "", no_wir_location());
}

func wir_lower_class_constructor(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, call: CallNode, info: StructInfo) -> WirExpr {
    let class_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, info.type_id);
    let class_pointer: WirType = program.arena.types[wir_id_index(UInt32(class_type))];
    if (class_pointer.kind != WirTypeKind.Pointer) {
        state.errors.append("class constructor reached WIR lowering without a pointer representation");
        return wir_no_expr();
    }
    let payload: WirTypeLayout = wir_type_layout(program, class_pointer.element);
    if (!payload.valid || payload.size > UInt64(wir_max_object_size(program.data_layout)) - UInt64(WIR_OBJECT_HEADER_SIZE)) {
        state.errors.append("class layout is too large for the target address space");
        return wir_no_expr();
    }

    let allocator: FuncInfo = wir_compiler_link_function(ref source, "memory_alloc");
    if (!has_func(allocator)) {
        state.errors.append("memory allocator is not available during WIR lowering");
        return wir_no_expr();
    }
    let allocator_id: WirFuncID = wir_find_function(program, allocator.name);
    if (allocator_id == NO_WIR_FUNC) { allocator_id = wir_lower_function_decl(ref types, ref source, ref program, allocator); }
    if (allocator_id == NO_WIR_FUNC) { return wir_no_expr(); }

    let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
    let total_size: UInt64 = payload.size + UInt64(WIR_OBJECT_HEADER_SIZE);
    let size: WirValueID = wir_const_int(ref program, size_type, UInt128(total_size));
    let raw: WirValueID = wir_call(ref program, state.block, wir_function_value(program, allocator_id), [size], "", no_wir_location());
    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [raw], [], no_wir_location());

    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let drop_id: WirFuncID = wir_class_drop_function(ref types, ref source, ref program, info);
    let drop_address: WirValueID = wir_const_address(ref program, raw_pointer, wir_function_value(program, drop_id), 0L);
    let drop_slot: WirValueID = wir_cast(ref program, state.block, raw, wir_pointer_type(ref program, raw_pointer), "", no_wir_location());
    wir_store(ref program, state.block, drop_address, drop_slot, no_wir_location());

    let uint32_type: WirTypeID = wir_unsigned_int_type(ref program, 32);
    let refcount_slot: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE + WIR_ARC_REFCOUNT_OFFSET, wir_pointer_type(ref program, uint32_type));
    let type_slot: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE + WIR_ARC_TYPE_OFFSET, wir_pointer_type(ref program, uint32_type));
    wir_store(ref program, state.block, wir_const_int(ref program, uint32_type, UInt128(0U)), refcount_slot, no_wir_location());
    wir_store(ref program, state.block, wir_const_int(ref program, uint32_type, UInt128(UInt32(info.type_id))), type_slot, no_wir_location());

    let object: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE, class_type);
    let field_index: Int = 0;
    while (info.fields is !null && field_index < info.fields.length()) {
        let field: FieldInfo = info.fields[field_index];
        let address: WirValueID = wir_field_address(ref program, state.block, object, field.offset, "", no_wir_location());
        if (field.name == "_vptr") {
            let table_id: WirGlobalID = wir_find_global(program, wir_class_vtable_name(info));
            if (table_id == NO_WIR_GLOBAL) {
                state.errors.append("class dispatch table was not emitted before construction");
                return wir_no_expr();
            }
            wir_store(ref program, state.block, wir_global_value(program, table_id), address, no_wir_location());
        } else {
            wir_store(ref program, state.block, wir_const_zero(ref program, wir_lower_source_type(ref types, ref source, ref program, field.type)), address, no_wir_location());
        }
        field_index++;
    }

    wir_call_class_field_initializers(ref state, ref types, ref source, ref program, info, object);
    let initializer: FuncInfo = source.func_table.lookup(info.name + "_$init");
    let argument_count: Int = 0;
    if (call.args is !null) { argument_count = call.args.length(); }
    if (!has_func(initializer)) {
        if (argument_count != 0) { state.errors.append("class constructor has arguments but no init method in WIR lowering"); return wir_no_expr(); }
    } else {
        if (initializer.variadic_param > 0) {
            state.errors.append("variadic class initializers are not lowered to WIR yet");
            return wir_no_expr();
        }
        let expected: Int = initializer.arg_types.length() - 1;
        if (argument_count != expected) {
            state.errors.append("class initializer reached WIR lowering with the wrong argument count");
            return wir_no_expr();
        }
        let initializer_id: WirFuncID = wir_find_function(program, initializer.name);
        if (initializer_id == NO_WIR_FUNC) { initializer_id = wir_lower_function_decl(ref types, ref source, ref program, initializer); }
        if (initializer_id == NO_WIR_FUNC) { return wir_no_expr(); }
        let owned_start: Int = state.owned_values.length();
        let arguments: Vector(WirValueID) = [object];
        let i: Int = 0;
        while (i < argument_count) {
            let argument: ArgNode = call.args[i];
            if (argument.name.length() != 0 || argument.is_spread) {
                state.errors.append("named and spread initializer arguments must be bound before WIR lowering");
                return wir_no_expr();
            }
            let parameter: TypeListNode = initializer.arg_types[i + 1];
            let value: WirExpr = wir_no_expr();
            if (parameter.pass_mode == PARAM_REF) {
                value = wir_lower_address(ref state, ref types, ref source, ref program, argument.val);
                if (value.value == NO_WIR_VALUE || value.source_type != parameter.type) {
                    state.errors.append("reference initializer argument has the wrong type in WIR lowering");
                    return wir_no_expr();
                }
            } else {
                value = wir_lower_expected_expr(ref state, ref types, ref source, ref program, argument.val, parameter.type);
                if (value.value == NO_WIR_VALUE) { return wir_no_expr(); }
                value = wir_cast_expr(ref state, ref types, ref source, ref program, value, parameter.type, true);
                if (value.value == NO_WIR_VALUE) { return wir_no_expr(); }
            }
            arguments.append(value.value);
            i++;
        }
        wir_call(ref program, state.block, wir_function_value(program, initializer_id), arguments, "", no_wir_location());
        wir_cleanup_temporaries(ref state, ref source, ref program, owned_start);
    }

    wir_track_owned(ref state, object, info.type_id);
    return WirExpr(value=object, source_type=info.type_id);
}

func wir_lower_interface_value(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirExpr, target_type: Int) -> WirExpr {
    let class_info: StructInfo = source.struct_id_map.lookup("" + get_repr_type(ref source, value.source_type));
    let interface_info: StructInfo = source.struct_id_map.lookup("" + get_repr_type(ref source, target_type));
    if (!has_struct(class_info) || !class_info.is_class || !has_struct(interface_info) || !interface_info.is_interface) { return wir_no_expr(); }
    if (!class_has_interface(ref source, class_info, interface_info)) {
        state.errors.append("class does not implement the target interface in WIR lowering");
        return wir_no_expr();
    }
    let table_id: WirGlobalID = wir_find_global(program, wir_interface_table_name(class_info, interface_info));
    if (table_id == NO_WIR_GLOBAL) {
        state.errors.append("interface dispatch table was not emitted before conversion");
        return wir_no_expr();
    }

    let object: WirValueID = wir_cast(ref program, state.block, value.value, wir_opaque_pointer(ref types, ref program), "", no_wir_location());
    let interface_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, target_type);
    let result: WirValueID = wir_struct_value(ref program, state.block, interface_type, [object, wir_global_value(program, table_id)], "", no_wir_location());
    if (wir_take_owned(ref state, value.value)) { wir_track_owned(ref state, result, target_type); }
    return WirExpr(value=result, source_type=target_type);
}

struct WirMemberCall(
    handled: Bool,
    value: WirExpr
)

func wir_interface_call_type(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, owner: StructInfo, method_node: MethodDefNode) -> WirTypeID {
    let parameters: Vector(WirTypeID) = [wir_opaque_pointer(ref types, ref program)];
    let i: Int = 0;
    while (method_node.params is !null && i < method_node.params.length()) {
        let parameter: ParamNode = method_node.params[i];
        let source_type: Int = interface_method_type(ref source, owner, parameter.type_tok);
        let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
        if (parameter.pass_mode == PARAM_REF) { type_id = wir_pointer_type(ref program, type_id); }
        parameters.append(type_id);
        i++;
    }
    let result_type: Int = interface_method_type(ref source, owner, method_node.return_type);
    let result: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, result_type);
    return wir_function_type(ref program, parameters, result, false, WirABI.White);
}

func wir_lower_interface_call(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, call: CallNode, access: FieldAccessNode, owner: StructInfo) -> WirMemberCall {
    let slot: Int = 0;
    while (owner.vtable is !null && slot < owner.vtable.length()) {
        let candidate: MethodDefNode = owner.vtable[slot];
        if (candidate.name_tok.value == access.field_name) { break; }
        slot++;
    }
    if (owner.vtable is null || slot >= owner.vtable.length()) { return WirMemberCall(handled=false, value=wir_no_expr()); }
    let method_node: MethodDefNode = owner.vtable[slot];
    if (call.args.length() != method_node.params.length()) {
        state.errors.append("Method '" + access.field_name + "' reached WIR lowering with the wrong argument count");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }

    let owned_start: Int = state.owned_values.length();
    let interface_value: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, access.obj);
    if (interface_value.value == NO_WIR_VALUE) { return WirMemberCall(handled=true, value=wir_no_expr()); }
    let object: WirValueID = wir_field(ref program, state.block, interface_value.value, 0, "", no_wir_location());
    let table: WirValueID = wir_field(ref program, state.block, interface_value.value, 1, "", no_wir_location());
    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [object], [], no_wir_location());
    let slot_index: WirValueID = wir_const_int(ref program, wir_unsigned_int_type(ref program, program.pointer_bits), UInt128(UIntSize(slot)));
    let method_slot: WirValueID = wir_index_address(ref program, state.block, table, slot_index, "", no_wir_location());
    let callee: WirValueID = wir_load(ref program, state.block, method_slot, "", no_wir_location());
    let arguments: Vector(WirValueID) = [object];

    let i: Int = 0;
    while (i < call.args.length()) {
        let argument: ArgNode = call.args[i];
        if (argument.name.length() != 0 || argument.is_spread) {
            state.errors.append("Named and spread method arguments must be bound before WIR lowering");
            return WirMemberCall(handled=true, value=wir_no_expr());
        }
        let parameter: ParamNode = method_node.params[i];
        let source_type: Int = interface_method_type(ref source, owner, parameter.type_tok);
        let value: WirExpr = wir_no_expr();
        if (parameter.pass_mode == PARAM_REF) {
            value = wir_lower_address(ref state, ref types, ref source, ref program, argument.val);
            if (value.value == NO_WIR_VALUE || value.source_type != source_type) {
                state.errors.append("Reference argument to method '" + access.field_name + "' has the wrong type in WIR lowering");
                return WirMemberCall(handled=true, value=wir_no_expr());
            }
        } else {
            value = wir_lower_expected_expr(ref state, ref types, ref source, ref program, argument.val, source_type);
            if (value.value == NO_WIR_VALUE) { return WirMemberCall(handled=true, value=wir_no_expr()); }
            value = wir_cast_expr(ref state, ref types, ref source, ref program, value, source_type, true);
            if (value.value == NO_WIR_VALUE) { return WirMemberCall(handled=true, value=wir_no_expr()); }
        }
        arguments.append(value.value);
        i++;
    }

    let call_type: WirTypeID = wir_interface_call_type(ref types, ref source, ref program, owner, method_node);
    let result_type: Int = interface_method_type(ref source, owner, method_node.return_type);
    let result: WirValueID = wir_call_typed(ref program, state.block, callee, call_type, arguments, "", no_wir_location());
    wir_cleanup_temporaries(ref state, ref source, ref program, owned_start);
    if (wir_value_needs_drop(ref source, result_type)) { wir_track_owned(ref state, result, result_type); }
    return WirMemberCall(handled=true, value=WirExpr(value=result, source_type=result_type));
}

func wir_lower_class_call(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, call: CallNode) -> WirMemberCall {
    if (!has_node(call.callee) || node_tag(call.callee) != NODE_FIELD_ACCESS) { return WirMemberCall(handled=false, value=wir_no_expr()); }
    let access: FieldAccessNode = get_field_access_node(source.arena, call.callee);
    let object_type: Int = get_repr_type(ref source, wir_lvalue_type(state, source, access.obj));
    let owner: StructInfo = source.struct_id_map.lookup("" + object_type);
    if (!has_struct(owner) || has_field(find_field(owner, access.field_name))) { return WirMemberCall(handled=false, value=wir_no_expr()); }
    if (owner.is_interface) { return wir_lower_interface_call(ref state, ref types, ref source, ref program, call, access, owner); }
    if (!owner.is_class) { return WirMemberCall(handled=false, value=wir_no_expr()); }

    let slot: Int = 0;
    let target: FuncInfo = FuncInfo();
    while (owner.vtable is !null && slot < owner.vtable.length()) {
        let candidate: FuncInfo = owner.vtable[slot];
        if (candidate.base_name == access.field_name) {
            target = candidate;
            break;
        }
        slot++;
    }
    if (!has_func(target)) { return WirMemberCall(handled=false, value=wir_no_expr()); }
    if (target.compiler_link_name is !null && target.compiler_link_name.length() != 0) {
        state.errors.append("Compiler-linked method '" + owner.name + "." + access.field_name + "' is not lowered to WIR yet");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    if (wir_lvalue_const(state, source, access.obj) && target.mutates_self) {
        state.errors.append("Mutating method '" + access.field_name + "' reached WIR lowering through a const value");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }

    let function_id: WirFuncID = wir_find_function(program, target.name);
    if (function_id == NO_WIR_FUNC) { function_id = wir_lower_function_decl(ref types, ref source, ref program, target); }
    if (function_id == NO_WIR_FUNC) { return WirMemberCall(handled=true, value=wir_no_expr()); }
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let signature: WirType = program.arena.types[wir_id_index(UInt32(function.type_id))];
    if (call.args.length() + 1 != signature.parameters.length()) {
        state.errors.append("Method '" + access.field_name + "' reached WIR lowering with the wrong argument count");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }

    let owned_start: Int = state.owned_values.length();
    let object: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, access.obj);
    if (object.value == NO_WIR_VALUE) { return WirMemberCall(handled=true, value=wir_no_expr()); }
    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [object.value], [], no_wir_location());
    let table_slot: WirValueID = wir_field_address(ref program, state.block, object.value, 0, "", no_wir_location());
    let table: WirValueID = wir_load(ref program, state.block, table_slot, "", no_wir_location());
    let slot_index: WirValueID = wir_const_int(ref program, wir_unsigned_int_type(ref program, program.pointer_bits), UInt128(UIntSize(slot)));
    let method_slot: WirValueID = wir_index_address(ref program, state.block, table, slot_index, "", no_wir_location());
    let callee: WirValueID = wir_load(ref program, state.block, method_slot, "", no_wir_location());

    let arguments: Vector(WirValueID) = [object.value];
    let i: Int = 0;
    while (i < call.args.length()) {
        let argument: ArgNode = call.args[i];
        if (argument.name.length() != 0 || argument.is_spread) {
            state.errors.append("Named and spread method arguments must be bound before WIR lowering");
            return WirMemberCall(handled=true, value=wir_no_expr());
        }
        let parameter: TypeListNode = target.arg_types[i + 1];
        let value: WirExpr = wir_no_expr();
        if (parameter.pass_mode == PARAM_REF) {
            value = wir_lower_address(ref state, ref types, ref source, ref program, argument.val);
            if (value.value == NO_WIR_VALUE || value.source_type != parameter.type) {
                state.errors.append("Reference argument to method '" + access.field_name + "' has the wrong type in WIR lowering");
                return WirMemberCall(handled=true, value=wir_no_expr());
            }
        } else {
            value = wir_lower_expected_expr(ref state, ref types, ref source, ref program, argument.val, parameter.type);
            if (value.value == NO_WIR_VALUE) { return WirMemberCall(handled=true, value=wir_no_expr()); }
            value = wir_cast_expr(ref state, ref types, ref source, ref program, value, parameter.type, true);
            if (value.value == NO_WIR_VALUE) { return WirMemberCall(handled=true, value=wir_no_expr()); }
        }
        arguments.append(value.value);
        i++;
    }

    let result: WirValueID = wir_call_typed(ref program, state.block, callee, function.type_id, arguments, "", no_wir_location());
    wir_cleanup_temporaries(ref state, ref source, ref program, owned_start);
    if (wir_value_needs_drop(ref source, target.ret_type)) { wir_track_owned(ref state, result, target.ret_type); }
    return WirMemberCall(handled=true, value=WirExpr(value=result, source_type=target.ret_type));
}

func wir_lower_expected_expr(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: NodeID, expected_type: Int) -> WirExpr {
    if (has_node(node) && node_tag(node) == NODE_VECTOR_LIT && expected_type != TYPE_AUTO && expected_type != TYPE_POISON) {
        return wir_lower_array_literal(ref state, ref types, ref source, ref program, node, expected_type);
    }
    return wir_lower_expr(ref state, ref types, ref source, ref program, node);
}

func wir_one(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, source_type: Int) -> WirValueID {
    let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);

    if (source_type == TYPE_FLOAT || source_type == TYPE_FLOAT32) {
        return wir_const_float(ref program, type_id, 1.0);
    }

    return wir_const_int(ref program, type_id, UInt128(1U));
}

func wir_binary_type(ref state: WirFunctionLowering, ref source: Compiler, left: WirExpr, right: WirExpr, left_node: NodeID, right_node: NodeID) -> Int {
    if (left.source_type == right.source_type) { return left.source_type; }
    if (!wir_source_numeric(left.source_type) || !wir_source_numeric(right.source_type)) { return TYPE_POISON; }
    if (left.source_type == TYPE_FLOAT || right.source_type == TYPE_FLOAT) { return TYPE_FLOAT; }
    if (left.source_type == TYPE_FLOAT32 || right.source_type == TYPE_FLOAT32) { return TYPE_FLOAT32; }

    if (is_signed_integer(left.source_type) != is_signed_integer(right.source_type)) {
        let left_bits: Int = get_type_bitwidth(left.source_type);
        let right_bits: Int = get_type_bitwidth(right.source_type);
        if (is_signed_integer(left.source_type) && left_bits > right_bits) { return left.source_type; }
        if (is_signed_integer(right.source_type) && right_bits > left_bits) { return right.source_type; }
        if (is_unsuffix_int_literal(ref source, left_node)) { return right.source_type; }
        if (is_unsuffix_int_literal(ref source, right_node)) { return left.source_type; }
        state.errors.append("signed and unsigned integers reached WIR lowering without an explicit conversion");
        return TYPE_POISON;
    }

    let left_bits: Int = get_type_bitwidth(left.source_type);
    let right_bits: Int = get_type_bitwidth(right.source_type);
    if (right_bits > left_bits) { return right.source_type; }
    if (left_bits > right_bits) { return left.source_type; }
    if (is_unsigned_integer(right.source_type)) { return right.source_type; }
    return left.source_type;
}

func wir_lower_expr(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: NodeID) -> WirExpr {
    if (!has_node(node)) {
        state.errors.append("expression is missing from the resolved AST");
        return wir_no_expr();
    }

    let kind: Int = node_tag(node);
    if (kind == NODE_INT) {
        let literal: IntNode = get_int_node(source.arena, node);
        let source_type: Int = get_expr_type(ref source, node);
        let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
        return WirExpr(value=wir_const_int(ref program, type_id, parse_const_uint128(literal.tok.value, literal.pos)), source_type=source_type);
    }
    if (kind == NODE_FLOAT) {
        let literal: FloatNode = get_float_node(source.arena, node);
        let source_type: Int = get_expr_type(ref source, node);
        let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
        return WirExpr(value=wir_const_float(ref program, type_id, parse_decimal_float_literal(literal.tok.value)), source_type=source_type);
    }
    if (kind == NODE_BOOL) {
        let literal: BooleanNode = get_bool_node(source.arena, node);
        return WirExpr(value=wir_const_bool(ref program, literal.value != 0), source_type=TYPE_BOOL);
    }
    if (kind == NODE_STRING) {
        let literal: StringNode = get_string_node(source.arena, node);
        return WirExpr(value=wir_lower_string_constant(ref types, ref program, literal.tok.value), source_type=TYPE_STRING);
    }
    if (kind == NODE_VAR_ACCESS) {
        let access: VarAccessNode = get_var_access_node(source.arena, node);
        if (!wir_name_is_value(state, source, access.name_tok.value)) {
            let info: FuncInfo = wir_source_function(ref source, access.name_tok.value);
            if (has_func(info)) {
                let function_id: WirFuncID = wir_find_function(program, info.name);
                if (function_id == NO_WIR_FUNC) { function_id = wir_lower_function_decl(ref types, ref source, ref program, info); }
                if (function_id == NO_WIR_FUNC) { return wir_no_expr(); }
                let source_type: Int = get_func_type_id(ref source, info.arg_types, info.ret_type, info.variadic_param, callable_arg_names(info, 0));
                let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
                let value: WirValueID = wir_function_value(program, function_id);
                if (type_id == NO_WIR_TYPE || wir_value_type(program, value) != type_id) {
                    state.errors.append("Function value '" + access.name_tok.value + "' does not match its WIR signature");
                    return wir_no_expr();
                }
                return WirExpr(value=value, source_type=source_type);
            }
        }
        let address: WirExpr = wir_lower_lvalue(ref state, ref types, ref source, ref program, node);
        if (address.value == NO_WIR_VALUE) { return wir_no_expr(); }
        return WirExpr(value=wir_load(ref program, state.block, address.value, "", no_wir_location()), source_type=address.source_type);
    }
    if (kind == NODE_FIELD_ACCESS) {
        let address: WirExpr = wir_lower_lvalue(ref state, ref types, ref source, ref program, node);
        if (address.value == NO_WIR_VALUE) { return wir_no_expr(); }
        return WirExpr(value=wir_load(ref program, state.block, address.value, "", no_wir_location()), source_type=address.source_type);
    }
    if (kind == NODE_REF) {
        let reference: RefNode = get_ref_node(source.arena, node);
        if (wir_lvalue_const(state, source, reference.node)) {
            state.errors.append("const value reached WIR lowering as a mutable reference");
            return wir_no_expr();
        }
        let address: WirExpr = wir_lower_lvalue(ref state, ref types, ref source, ref program, reference.node);
        if (address.value == NO_WIR_VALUE) { return wir_no_expr(); }
        return WirExpr(value=address.value, source_type=get_ptr_type_id(ref source, address.source_type));
    }
    if (kind == NODE_DEREF) {
        let dereference: DerefNode = get_deref_node(source.arena, node);
        let value: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, dereference.node);
        if (value.value == NO_WIR_VALUE) { return wir_no_expr(); }
        let level: Int = 0;
        while (level < dereference.level) {
            let pointer: SymbolInfo = source.ptr_base_map.lookup("" + value.source_type);
            if (!has_symbol(pointer) || pointer.type == TYPE_VOID) {
                state.errors.append("invalid pointer dereference reached WIR lowering");
                return wir_no_expr();
            }
            wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [value.value], [], no_wir_location());
            value = WirExpr(value=wir_load(ref program, state.block, value.value, "", no_wir_location()), source_type=pointer.type);
            level++;
        }
        return value;
    }
    if (kind == NODE_NULLPTR) {
        let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, TYPE_NULLPTR);
        return WirExpr(value=wir_null(ref program, type_id), source_type=TYPE_NULLPTR);
    }
    if (kind == NODE_INDEX_ACCESS) {
        let address: WirExpr = wir_lower_lvalue(ref state, ref types, ref source, ref program, node);
        if (address.value == NO_WIR_VALUE) { return wir_no_expr(); }
        return WirExpr(value=wir_load(ref program, state.block, address.value, "", no_wir_location()), source_type=address.source_type);
    }
    if (kind == NODE_UNARYOP) {
        let unary: UnaryOpNode = get_unary_node(source.arena, node);
        let operand: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, unary.node);
        if (operand.value == NO_WIR_VALUE) { return wir_no_expr(); }

        if (unary.op_tok.type == TOK_PLUS) {
            if (!wir_source_numeric(operand.source_type)) {
                state.errors.append("unary '+' reached WIR lowering with a non-numeric operand");
                return wir_no_expr();
            }
            return operand;
        }

        let opcode: WirOpcode = WirOpcode.Invalid;
        if (unary.op_tok.type == TOK_SUB) {
            if (is_integer_type(operand.source_type)) { opcode = WirOpcode.Negate; }
            else if (operand.source_type == TYPE_FLOAT || operand.source_type == TYPE_FLOAT32) { opcode = WirOpcode.FloatNegate; }
            else { state.errors.append("unary '-' reached WIR lowering with a non-numeric operand"); }
        } else if (unary.op_tok.type == TOK_NOT) {
            if (operand.source_type == TYPE_BOOL) { opcode = WirOpcode.Not; }
            else { state.errors.append("operator '!' reached WIR lowering with a non-Bool operand"); }
        } else if (unary.op_tok.type == TOK_BIT_NOT) {
            if (is_integer_type(operand.source_type)) { opcode = WirOpcode.Not; }
            else { state.errors.append("operator '~' reached WIR lowering with a non-integer operand"); }
        } else {
            state.errors.append("unary operator '" + unary.op_tok.value + "' is not lowered to WIR yet");
        }
        if (opcode == WirOpcode.Invalid) { return wir_no_expr(); }

        let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, operand.source_type);
        return WirExpr(value=wir_unary(ref program, state.block, opcode, type_id, operand.value, "", no_wir_location()), source_type=operand.source_type);
    }
    if (kind == NODE_POSTFIX) {
        let postfix: PostfixOpNode = get_postfix_node(source.arena, node);
        if (!has_node(postfix.node) || node_tag(postfix.node) != NODE_VAR_ACCESS) {
            state.errors.append("postfix operator target is not an addressable local in WIR lowering");
            return wir_no_expr();
        }

        let access: VarAccessNode = get_var_access_node(source.arena, postfix.node);
        let binding: WirBinding = wir_find_binding(state, access.name_tok.value)?;
        catch(err) {
            state.errors.append("unknown local '" + access.name_tok.value + "' in WIR postfix lowering");
            return wir_no_expr();
        }

        if (binding.is_const) {
            state.errors.append("const local '" + access.name_tok.value + "' reached WIR postfix lowering");
            return wir_no_expr();
        }

        if (!wir_source_numeric(binding.source_type)) {
            state.errors.append("postfix operator reached WIR lowering with a non-numeric operand");
            return wir_no_expr();
        }

        let old_value: WirValueID = wir_load(ref program, state.block, binding.address, "", no_wir_location());
        let one: WirValueID = wir_one(ref types, ref source, ref program, binding.source_type);
        let opcode: WirOpcode = WirOpcode.Add;

        if (postfix.op_tok.type == TOK_DEC) {
            opcode = WirOpcode.Subtract;
        }

        let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, binding.source_type);
        let new_value: WirValueID = wir_binary(ref program, state.block, opcode, type_id, old_value, one, "", no_wir_location());
        wir_store(ref program, state.block, new_value, binding.address, no_wir_location());
        return WirExpr(value=old_value, source_type=binding.source_type);
    }
    if (kind == NODE_BINOP) {
        let binary: BinOpNode = get_binop_node(source.arena, node);
        if (binary.op_tok.type == TOK_AND || binary.op_tok.type == TOK_OR) {
            let left: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, binary.left);
            if (left.value == NO_WIR_VALUE) { return wir_no_expr(); }
            if (left.source_type != TYPE_BOOL) {
                state.errors.append("logical operator reached WIR lowering with a non-Bool left operand");
                return wir_no_expr();
            }

            let right_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "logic.rhs."), []);
            let merge_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "logic.end."), [wir_param("value", program.bool_type)]);
            let short_value: WirValueID = wir_const_bool(ref program, binary.op_tok.type == TOK_OR);
            if (binary.op_tok.type == TOK_AND) {
                wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [left.value], [wir_edge(right_block, []), wir_edge(merge_block, [short_value])], no_wir_location());
            } else {
                wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [left.value], [wir_edge(merge_block, [short_value]), wir_edge(right_block, [])], no_wir_location());
            }

            state.block = right_block;
            let right: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, binary.right);
            if (right.value == NO_WIR_VALUE) { return wir_no_expr(); }
            if (right.source_type != TYPE_BOOL) {
                state.errors.append("logical operator reached WIR lowering with a non-Bool right operand");
                return wir_no_expr();
            }
            wir_append(ref program, right_block, WirOpcode.Jump, program.void_type, [], [wir_edge(merge_block, [right.value])], no_wir_location());
            state.block = merge_block;
            let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(merge_block))];
            return WirExpr(value=block.parameters[0], source_type=TYPE_BOOL);
        }

        let left: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, binary.left);
        let right: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, binary.right);
        if (left.value == NO_WIR_VALUE || right.value == NO_WIR_VALUE) { return wir_no_expr(); }
        let common_type: Int = wir_binary_type(ref state, ref source, left, right, binary.left, binary.right);
        if (common_type == TYPE_POISON) {
            if (state.errors.length() == 0) { state.errors.append("binary operands reached WIR lowering with incompatible types"); }
            return wir_no_expr();
        }
        left = wir_cast_expr(ref state, ref types, ref source, ref program, left, common_type, false);
        right = wir_cast_expr(ref state, ref types, ref source, ref program, right, common_type, false);
        if (left.value == NO_WIR_VALUE || right.value == NO_WIR_VALUE) { return wir_no_expr(); }

        let opcode: WirOpcode = wir_comparison_opcode(common_type, binary.op_tok.type);
        if (opcode != WirOpcode.Invalid) {
            let value: WirValueID = wir_binary(ref program, state.block, opcode, program.bool_type, left.value, right.value, "", no_wir_location());
            return WirExpr(value=value, source_type=TYPE_BOOL);
        }

        opcode = wir_numeric_opcode(common_type, binary.op_tok.type);
        if (opcode == WirOpcode.Invalid) {
            state.errors.append("binary operator '" + binary.op_tok.value + "' is not lowered to WIR yet");
            return wir_no_expr();
        }
        let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, common_type);
        let value: WirValueID = wir_binary(ref program, state.block, opcode, type_id, left.value, right.value, "", no_wir_location());
        return WirExpr(value=value, source_type=common_type);
    }
    if (kind == NODE_CALL) {
        let call: CallNode = get_call_node(source.arena, node);
        let member_call: WirMemberCall = wir_lower_class_call(ref state, ref types, ref source, ref program, call);
        if (member_call.handled) { return member_call.value; }
        let constructor: StructInfo = wir_struct_constructor(ref source, call.callee);
        if (has_struct(constructor) && !constructor.is_interface && !constructor.is_enum) {
            if (constructor.is_class) { return wir_lower_class_constructor(ref state, ref types, ref source, ref program, call, constructor); }
            return wir_lower_struct_constructor(ref state, ref types, ref source, ref program, call, constructor);
        }
        if (call.preserve_fallible) {
            state.errors.append("fallible calls are not lowered to WIR yet");
            return wir_no_expr();
        }

        let info: FuncInfo = FuncInfo();
        if (node_tag(call.callee) == NODE_VAR_ACCESS) {
            let direct: VarAccessNode = get_var_access_node(source.arena, call.callee);
            if (!wir_name_is_value(state, source, direct.name_tok.value)) {
                info = wir_source_function(ref source, direct.name_tok.value);
            }
        }

        let callee_value: WirValueID = NO_WIR_VALUE;
        let signature_info: SymbolInfo = SymbolInfo();
        let result_type: Int = TYPE_POISON;
        let callable_name: String = "function value";
        if (has_func(info)) {
            let function_id: WirFuncID = wir_find_function(program, info.name);
            if (function_id == NO_WIR_FUNC) { function_id = wir_lower_function_decl(ref types, ref source, ref program, info); }
            if (function_id == NO_WIR_FUNC) { return wir_no_expr(); }
            callee_value = wir_function_value(program, function_id);
            signature_info = SymbolInfo(type=info.ret_type, func_arg_types=info.arg_types, arg_names=info.arg_names, variadic_param=info.variadic_param);
            result_type = info.ret_type;
            callable_name = info.name;
        } else {
            let indirect: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, call.callee);
            if (indirect.value == NO_WIR_VALUE) { return wir_no_expr(); }
            if (source.method_ret_map is !null && has_symbol(source.method_ret_map.lookup("" + indirect.source_type))) {
                state.errors.append("Bound method values are not lowered to WIR yet");
                return wir_no_expr();
            }
            if (source.func_ret_map is null) {
                state.errors.append("Indirect call has no resolved function signature");
                return wir_no_expr();
            }
            signature_info = source.func_ret_map.lookup("" + indirect.source_type);
            if (!has_symbol(signature_info)) {
                state.errors.append("Indirect call target does not have a Function type");
                return wir_no_expr();
            }
            callee_value = indirect.value;
            result_type = signature_info.type;
        }

        let signature: WirType = program.arena.types[wir_id_index(UInt32(wir_value_type(program, callee_value)))];
        let owned_start: Int = state.owned_values.length();
        let arguments: Vector(WirValueID) = [];
        let i: Int = 0;
        while (i < call.args.length()) {
            let argument: ArgNode = call.args[i];
            if (argument.name.length() != 0 || argument.is_spread) {
                state.errors.append("named and spread arguments must be bound before WIR lowering");
                return wir_no_expr();
            }
            let value: WirExpr = wir_no_expr();
            if (i < signature.parameters.length()) {
                let parameter: TypeListNode = signature_info.func_arg_types[i];
                if (parameter.pass_mode == PARAM_REF) {
                    value = wir_lower_address(ref state, ref types, ref source, ref program, argument.val);
                    if (value.value == NO_WIR_VALUE) { return wir_no_expr(); }
                    if (value.source_type != parameter.type) {
                        state.errors.append("Reference argument to '" + callable_name + "' has the wrong type in WIR lowering");
                        return wir_no_expr();
                    }
                } else {
                    value = wir_lower_expected_expr(ref state, ref types, ref source, ref program, argument.val, parameter.type);
                    if (value.value == NO_WIR_VALUE) { return wir_no_expr(); }
                    value = wir_cast_expr(ref state, ref types, ref source, ref program, value, parameter.type, true);
                    if (value.value == NO_WIR_VALUE) { return wir_no_expr(); }
                }
            } else {
                value = wir_lower_expr(ref state, ref types, ref source, ref program, argument.val);
                if (value.value == NO_WIR_VALUE) { return wir_no_expr(); }
            }
            arguments.append(value.value);
            i++;
        }
        let result: WirValueID = wir_call(ref program, state.block, callee_value, arguments, "", no_wir_location());
        wir_cleanup_temporaries(ref state, ref source, ref program, owned_start);
        if (wir_value_needs_drop(ref source, result_type)) { wir_track_owned(ref state, result, result_type); }
        return WirExpr(value=result, source_type=result_type);
    }

    state.errors.append("AST node kind " + kind + " is not lowered to WIR yet");
    return wir_no_expr();
}

func wir_lower_var(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: VarDeclareNode) -> Void {
    let source_type: Int = TYPE_AUTO;
    if (has_node(node.type_node)) {
        let declared: Int = resolve_type(ref source, node.type_node);
        if (declared != TYPE_AUTO) { source_type = declared; }
    }
    let value: WirExpr = wir_lower_expected_expr(ref state, ref types, ref source, ref program, node.value, source_type);
    if (value.value == NO_WIR_VALUE) { return; }
    if (source_type == TYPE_AUTO) { source_type = value.source_type; }
    value = wir_cast_expr(ref state, ref types, ref source, ref program, value, source_type, true);
    if (value.value == NO_WIR_VALUE) { return; }

    let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
    let address: WirValueID = wir_stack_alloc(ref program, state.entry, type_id, node.name_tok.value + ".addr", no_wir_location());
    wir_move_or_retain(ref state, ref source, ref program, value);
    wir_store(ref program, state.block, value.value, address, no_wir_location());
    let owns_value: Bool = wir_value_needs_drop(ref source, source_type);
    state.bindings.append(WirBinding(name=node.name_tok.value, source_type=source_type, address=address, is_const=node.is_const, owns_value=owns_value));
}

func wir_lower_stmt(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: NodeID) -> Void {
    if (state.terminated || !has_node(node)) { return; }
    let kind: Int = node_tag(node);
    if (kind == NODE_VAR_DECL) {
        wir_lower_var(ref state, ref types, ref source, ref program, get_var_decl_node(source.arena, node));
        return;
    }
    if (kind == NODE_VAR_ASSIGN) {
        let statement: VarAssignNode = get_var_assign_node(source.arena, node);
        let binding: WirBinding = wir_find_binding(state, statement.name_tok.value)?;
        catch(err) {
            let global: WirSourceGlobal = wir_source_global(ref source, statement.name_tok.value);
            let global_id: WirGlobalID = NO_WIR_GLOBAL;
            if (has_wir_source_global(global)) { global_id = wir_find_global(program, global.name); }
            if (global_id == NO_WIR_GLOBAL) {
                state.errors.append("unknown value '" + statement.name_tok.value + "' in WIR lowering");
                return;
            }
            if (global.is_const) {
                state.errors.append("const global '" + statement.name_tok.value + "' reached WIR lowering with an assignment");
                return;
            }
            let global_value: WirExpr = wir_lower_expected_expr(ref state, ref types, ref source, ref program, statement.value, global.source_type);
            if (global_value.value == NO_WIR_VALUE) { return; }
            global_value = wir_cast_expr(ref state, ref types, ref source, ref program, global_value, global.source_type, true);
            if (global_value.value == NO_WIR_VALUE) { return; }
            let global_address: WirValueID = wir_global_value(program, global_id);
            wir_move_or_retain(ref state, ref source, ref program, global_value);
            wir_emit_ownership_slot(ref state, ref source, ref program, global_address, global.source_type, false);
            wir_store(ref program, state.block, global_value.value, global_address, no_wir_location());
            return;
        }
        if (binding.is_const) {
            state.errors.append("const local '" + statement.name_tok.value + "' reached WIR lowering with an assignment");
            return;
        }
        let value: WirExpr = wir_lower_expected_expr(ref state, ref types, ref source, ref program, statement.value, binding.source_type);
        if (value.value == NO_WIR_VALUE) { return; }
        value = wir_cast_expr(ref state, ref types, ref source, ref program, value, binding.source_type, true);
        if (value.value == NO_WIR_VALUE) { return; }
        wir_move_or_retain(ref state, ref source, ref program, value);
        wir_emit_ownership_slot(ref state, ref source, ref program, binding.address, binding.source_type, false);
        wir_store(ref program, state.block, value.value, binding.address, no_wir_location());
        return;
    }
    if (kind == NODE_FIELD_ASSIGN) {
        let statement: FieldAssignNode = get_field_assign_node(source.arena, node);
        if (wir_field_const(state, source, statement.obj, statement.field_name)) {
            state.errors.append("const field reached WIR lowering with an assignment");
            return;
        }
        let address: WirExpr = wir_lower_field_lvalue(ref state, ref types, ref source, ref program, statement.obj, statement.field_name);
        if (address.value == NO_WIR_VALUE) { return; }
        let value: WirExpr = wir_lower_expected_expr(ref state, ref types, ref source, ref program, statement.value, address.source_type);
        if (value.value == NO_WIR_VALUE) { return; }
        value = wir_cast_expr(ref state, ref types, ref source, ref program, value, address.source_type, true);
        if (value.value == NO_WIR_VALUE) { return; }
        wir_move_or_retain(ref state, ref source, ref program, value);
        wir_emit_ownership_slot(ref state, ref source, ref program, address.value, address.source_type, false);
        wir_store(ref program, state.block, value.value, address.value, no_wir_location());
        return;
    }
    if (kind == NODE_INDEX_ASSIGN) {
        let statement: IndexAssignNode = get_index_assign_node(source.arena, node);
        if (wir_lvalue_const(state, source, statement.target)) {
            state.errors.append("const array reached WIR lowering with an index assignment");
            return;
        }
        let address: WirExpr = wir_lower_index_lvalue(ref state, ref types, ref source, ref program, statement.target, statement.index_node);
        if (address.value == NO_WIR_VALUE) { return; }
        let value: WirExpr = wir_lower_expected_expr(ref state, ref types, ref source, ref program, statement.value, address.source_type);
        if (value.value == NO_WIR_VALUE) { return; }
        value = wir_cast_expr(ref state, ref types, ref source, ref program, value, address.source_type, true);
        if (value.value == NO_WIR_VALUE) { return; }
        wir_move_or_retain(ref state, ref source, ref program, value);
        wir_emit_ownership_slot(ref state, ref source, ref program, address.value, address.source_type, false);
        wir_store(ref program, state.block, value.value, address.value, no_wir_location());
        return;
    }
    if (kind == NODE_PTR_ASSIGN) {
        let statement: PtrAssignNode = get_ptr_assign_node(source.arena, node);
        let dereference: DerefNode = get_deref_node(source.arena, statement.pointer);
        if (wir_lvalue_const(state, source, dereference.node)) {
            state.errors.append("const pointer reached WIR lowering with an indirect assignment");
            return;
        }
        let pointer: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, dereference.node);
        if (pointer.value == NO_WIR_VALUE) { return; }
        let level: Int = 0;
        while (level + 1 < dereference.level) {
            let base: SymbolInfo = source.ptr_base_map.lookup("" + pointer.source_type);
            if (!has_symbol(base) || base.type == TYPE_VOID) {
                state.errors.append("invalid pointer assignment reached WIR lowering");
                return;
            }
            wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [pointer.value], [], no_wir_location());
            pointer = WirExpr(value=wir_load(ref program, state.block, pointer.value, "", no_wir_location()), source_type=base.type);
            level++;
        }
        let target: SymbolInfo = source.ptr_base_map.lookup("" + pointer.source_type);
        if (!has_symbol(target) || target.type == TYPE_VOID) {
            state.errors.append("pointer assignment target is not a typed pointer in WIR lowering");
            return;
        }
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [pointer.value], [], no_wir_location());
        let value: WirExpr = wir_lower_expected_expr(ref state, ref types, ref source, ref program, statement.value, target.type);
        if (value.value == NO_WIR_VALUE) { return; }
        value = wir_cast_expr(ref state, ref types, ref source, ref program, value, target.type, true);
        if (value.value == NO_WIR_VALUE) { return; }
        wir_move_or_retain(ref state, ref source, ref program, value);
        wir_emit_ownership_slot(ref state, ref source, ref program, pointer.value, target.type, false);
        wir_store(ref program, state.block, value.value, pointer.value, no_wir_location());
        return;
    }
    if (kind == NODE_POSTFIX) {
        wir_lower_expr(ref state, ref types, ref source, ref program, node);
        return;
    }
    if (kind == NODE_CALL) {
        wir_lower_expr(ref state, ref types, ref source, ref program, node);
        return;
    }
    if (kind == NODE_RETURN) {
        let statement: ReturnNode = get_return_node(source.arena, node);
        let function: WirFunction = program.arena.functions[wir_id_index(UInt32(state.function))];
        let signature: WirType = program.arena.types[wir_id_index(UInt32(function.type_id))];
        let result: WirExpr = wir_no_expr();
        if (has_node(statement.value)) { result = wir_lower_expected_expr(ref state, ref types, ref source, ref program, statement.value, state.return_type); }
        if (signature.result == program.void_type) {
            if (result.value != NO_WIR_VALUE) { state.errors.append("Void function reached WIR lowering with a return value"); return; }
        } else if (result.value == NO_WIR_VALUE) {
            state.errors.append("non-Void function reached WIR lowering without a return value");
            return;
        } else {
            result = wir_cast_expr(ref state, ref types, ref source, ref program, result, state.return_type, true);
            if (result.value == NO_WIR_VALUE || wir_value_type(program, result.value) != signature.result) {
                state.errors.append("return value reached WIR lowering with the wrong type");
                return;
            }
            wir_move_or_retain(ref state, ref source, ref program, result);
        }
        wir_cleanup_temporaries(ref state, ref source, ref program, 0);
        wir_cleanup_bindings(ref state, ref source, ref program, 0);
        wir_return(ref program, state.block, result.value, no_wir_location());
        state.terminated = true;
        return;
    }
    if (kind == NODE_IF) {
        let statement: IfNode = get_if_node(source.arena, node);
        let condition: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, statement.condition);
        if (condition.value == NO_WIR_VALUE) { return; }
        if (condition.source_type != TYPE_BOOL) {
            state.errors.append("if condition reached WIR lowering with a non-Bool type");
            return;
        }

        let parent_bindings: Int = state.bindings.length();
        let then_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "if.then."), []);
        if (!has_node(statement.else_body)) {
            let merge_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "if.end."), []);
            wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [condition.value], [wir_edge(then_block, []), wir_edge(merge_block, [])], no_wir_location());

            state.block = then_block;
            state.terminated = false;
            wir_lower_block(ref state, ref types, ref source, ref program, statement.body);
            if (!state.terminated) { wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(merge_block, [])], no_wir_location()); }

            wir_restore_bindings(ref state, parent_bindings);
            state.block = merge_block;
            state.terminated = false;
            return;
        }

        let else_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "if.else."), []);
        wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [condition.value], [wir_edge(then_block, []), wir_edge(else_block, [])], no_wir_location());

        state.block = then_block;
        state.terminated = false;
        wir_lower_block(ref state, ref types, ref source, ref program, statement.body);
        let then_end: WirBlockID = state.block;
        let then_terminated: Bool = state.terminated;

        wir_restore_bindings(ref state, parent_bindings);
        state.block = else_block;
        state.terminated = false;
        if (node_tag(statement.else_body) == NODE_IF) {
            wir_lower_stmt(ref state, ref types, ref source, ref program, statement.else_body);
        } else {
            wir_lower_block(ref state, ref types, ref source, ref program, statement.else_body);
        }
        let else_end: WirBlockID = state.block;
        let else_terminated: Bool = state.terminated;

        wir_restore_bindings(ref state, parent_bindings);
        if (then_terminated && else_terminated) {
            state.terminated = true;
            return;
        }

        let merge_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "if.end."), []);
        if (!then_terminated) { wir_append(ref program, then_end, WirOpcode.Jump, program.void_type, [], [wir_edge(merge_block, [])], no_wir_location()); }
        if (!else_terminated) { wir_append(ref program, else_end, WirOpcode.Jump, program.void_type, [], [wir_edge(merge_block, [])], no_wir_location()); }
        state.block = merge_block;
        state.terminated = false;
        return;
    }
    if (kind == NODE_WHILE) {
        let statement: WhileNode = get_while_node(source.arena, node);
        let condition_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "while.cond."), []);
        let body_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "while.body."), []);
        let end_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "while.end."), []);
        wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(condition_block, [])], no_wir_location());

        state.block = condition_block;
        state.terminated = false;
        let condition: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, statement.condition);
        if (condition.value == NO_WIR_VALUE) { return; }
        if (condition.source_type != TYPE_BOOL) {
            state.errors.append("while condition reached WIR lowering with a non-Bool type");
            return;
        }
        wir_append(ref program, condition_block, WirOpcode.Branch, program.void_type, [condition.value], [wir_edge(body_block, []), wir_edge(end_block, [])], no_wir_location());

        state.loops.append(WirLoop(continue_block=condition_block, break_block=end_block, binding_count=state.bindings.length()));
        state.block = body_block;
        state.terminated = false;
        wir_lower_block(ref state, ref types, ref source, ref program, statement.body);
        if (!state.terminated) { wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(condition_block, [])], no_wir_location()); }
        let loops: Vector(WirLoop) = [];
        let loop_index: Int = 0;
        while (loop_index + 1 < state.loops.length()) {
            loops.append(state.loops[loop_index]);
            loop_index++;
        }
        state.loops = loops;
        state.block = end_block;
        state.terminated = false;
        return;
    }
    if (kind == NODE_BREAK || kind == NODE_CONTINUE) {
        if (state.loops.length() == 0) {
            state.errors.append("loop control reached WIR lowering outside a loop");
            return;
        }
        let loop: WirLoop = state.loops[state.loops.length() - 1];
        let target: WirBlockID = loop.break_block;
        if (kind == NODE_CONTINUE) { target = loop.continue_block; }
        wir_cleanup_temporaries(ref state, ref source, ref program, 0);
        wir_cleanup_bindings(ref state, ref source, ref program, loop.binding_count);
        wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(target, [])], no_wir_location());
        state.terminated = true;
        return;
    }
    state.errors.append("statement kind " + kind + " is not lowered to WIR yet");
}

func wir_lower_block(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: NodeID) -> Void {
    if (!has_node(node) || node_tag(node) != NODE_BLOCK) {
        state.errors.append("function body is not a block");
        return;
    }
    let block: BlockNode = get_block_node(source.arena, node);
    let binding_count: Int = state.bindings.length();
    let i: Int = 0;
    while (i < block.stmts.length() && !state.terminated) {
        let temporary_count: Int = state.owned_values.length();
        wir_lower_stmt(ref state, ref types, ref source, ref program, block.stmts[i]);
        if (!state.terminated) { wir_cleanup_temporaries(ref state, ref source, ref program, temporary_count); }
        i++;
    }
    if (!state.terminated) { wir_cleanup_bindings(ref state, ref source, ref program, binding_count); }
    wir_restore_bindings(ref state, binding_count);
}

func wir_lower_function_body(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, info: FuncInfo, body: NodeID) -> WirFuncID {
    let function_id: WirFuncID = wir_find_function(program, info.name);
    if (function_id == NO_WIR_FUNC) { function_id = wir_lower_function_decl(ref types, ref source, ref program, info); }
    if (function_id == NO_WIR_FUNC) { return NO_WIR_FUNC; }
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    if (function.linkage == WirLinkage.External) {
        types.errors.append("external function '" + info.name + "' has a body");
        return function_id;
    }
    if (function.blocks.length() != 0) {
        types.errors.append("function '" + info.name + "' has more than one WIR body");
        return function_id;
    }

    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let state: WirFunctionLowering = WirFunctionLowering(function=function_id, return_type=info.ret_type, entry=entry, block=entry, bindings=[], loops=[], owned_values=[], errors=[], terminated=false, next_block=0);
    let i: Int = 0;
    while (i < function.parameters.length()) {
        let parameter: WirValueID = function.parameters[i];
        let source_parameter: TypeListNode = info.arg_types[i];
        let name: String = program.arena.values[wir_id_index(UInt32(parameter))].name;
        if (source_parameter.pass_mode == PARAM_REF) {
            state.bindings.append(WirBinding(name=name, source_type=source_parameter.type, address=parameter, is_const=false, owns_value=false));
        } else {
            let source_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_parameter.type);
            let address: WirValueID = wir_stack_alloc(ref program, entry, source_type, name + ".addr", no_wir_location());
            wir_store(ref program, entry, parameter, address, no_wir_location());
            let owns_value: Bool = wir_value_needs_drop(ref source, source_parameter.type);
            if (owns_value) { wir_emit_ownership_value(ref state, ref source, ref program, parameter, source_parameter.type, true); }
            state.bindings.append(WirBinding(name=name, source_type=source_parameter.type, address=address, is_const=false, owns_value=owns_value));
        }
        i++;
    }

    wir_lower_block(ref state, ref types, ref source, ref program, body);
    let signature: WirType = program.arena.types[wir_id_index(UInt32(function.type_id))];
    if (!state.terminated) {
        if (signature.result == program.void_type) {
            wir_cleanup_temporaries(ref state, ref source, ref program, 0);
            wir_cleanup_bindings(ref state, ref source, ref program, 0);
            wir_return(ref program, state.block, NO_WIR_VALUE, no_wir_location());
        } else {
            state.errors.append("function '" + info.name + "' has no terminating return in WIR lowering");
        }
    }
    i = 0;
    while (i < state.errors.length()) {
        types.errors.append(state.errors[i]);
        i++;
    }
    return function_id;
}
