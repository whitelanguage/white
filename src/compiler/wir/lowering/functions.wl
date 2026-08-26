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
import target_intrinsic_symbol, target_value from "../../target_eval.wl"
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
    if (source.func_table is null) { return FuncInfo(); }
    let info: FuncInfo = source.func_table.lookup(name);
    if (!has_func(info) && source.current_file_func_aliases is !null) {
        let mapped: String = source.current_file_func_aliases.lookup(name);
        if (mapped is !null) { info = source.func_table.lookup(mapped); }
    }
    if (!has_func(info) && source.current_package_prefix.length() != 0) {
        info = source.func_table.lookup(source.current_package_prefix + name);
    }
    if (!has_func(info) && source.global_func_aliases is !null) {
        let mapped: String = source.global_func_aliases.lookup(name);
        if (mapped is !null) { info = source.func_table.lookup(mapped); }
    }
    return info;
}

func wir_direct_function(ref state: WirFunctionLowering, ref source: Compiler, callee: NodeID) -> FuncInfo {
    if (!has_node(callee)) { return FuncInfo(); }
    let kind: Int = node_tag(callee);
    if (kind == NODE_VAR_ACCESS) {
        let name: String = get_var_access_node(source.arena, callee).name_tok.value;
        if (!wir_name_is_value(state, source, name)) { return wir_source_function(ref source, name); }
        return FuncInfo();
    }
    if (kind != NODE_FIELD_ACCESS) { return FuncInfo(); }

    let access: FieldAccessNode = get_field_access_node(source.arena, callee);
    let path: Vector(String) = [];
    let root_node: NodeID = access.obj;
    while (has_node(root_node) && node_tag(root_node) == NODE_FIELD_ACCESS) {
        let part: FieldAccessNode = get_field_access_node(source.arena, root_node);
        path.append(part.field_name);
        root_node = part.obj;
    }
    if (has_node(root_node) && node_tag(root_node) == NODE_VAR_ACCESS) {
        let root: String = get_var_access_node(source.arena, root_node).name_tok.value;
        if (!wir_name_is_value(state, source, root)) {
            let name: String = "";
            if (source.current_file_visible_prefixes is !null) {
                let prefix: String = source.current_file_visible_prefixes.lookup(root);
                if (prefix is !null) { name = module_member_name(prefix, path, access.field_name); }
            }
            if (name.length() == 0 && source.current_file_func_aliases is !null) {
                let source_name: String = module_member_name(root + ".", path, access.field_name);
                let mapped: String = source.current_file_func_aliases.lookup(source_name);
                if (mapped is !null) { name = mapped; }
            }
            if (name.length() != 0) {
                let info: FuncInfo = wir_source_function(ref source, name);
                if (has_func(info)) { return info; }
            }
        }
    }
    return wir_source_function(ref source, format_ast_path(ref source, callee));
}

func wir_direct_global(ref state: WirFunctionLowering, ref source: Compiler, node: NodeID) -> WirSourceGlobal {
    if (!has_node(node)) { return no_wir_source_global(); }
    if (node_tag(node) == NODE_VAR_ACCESS) {
        return wir_source_global(ref source, get_var_access_node(source.arena, node).name_tok.value);
    }
    if (node_tag(node) != NODE_FIELD_ACCESS) { return no_wir_source_global(); }

    let access: FieldAccessNode = get_field_access_node(source.arena, node);
    let path: Vector(String) = [];
    let root_node: NodeID = access.obj;
    while (has_node(root_node) && node_tag(root_node) == NODE_FIELD_ACCESS) {
        let part: FieldAccessNode = get_field_access_node(source.arena, root_node);
        path.append(part.field_name);
        root_node = part.obj;
    }
    if (has_node(root_node) && node_tag(root_node) == NODE_VAR_ACCESS) {
        let root: String = get_var_access_node(source.arena, root_node).name_tok.value;
        if (!wir_name_is_value(state, source, root)) {
            let name: String = "";
            if (source.current_file_visible_prefixes is !null) {
                let prefix: String = source.current_file_visible_prefixes.lookup(root);
                if (prefix is !null) { name = module_member_name(prefix, path, access.field_name); }
            }
            if (name.length() == 0 && source.current_file_global_aliases is !null) {
                let source_name: String = module_member_name(root + ".", path, access.field_name);
                let mapped: String = source.current_file_global_aliases.lookup(source_name);
                if (mapped is !null) { name = mapped; }
            }
            if (name.length() != 0) {
                let global: WirSourceGlobal = wir_source_global(ref source, name);
                if (has_wir_source_global(global)) { return global; }
            }
        }
    }
    return wir_source_global(ref source, format_ast_path(ref source, node));
}

func wir_cast_target(ref source: Compiler, callee: NodeID) -> Int {
    let kind: Int = node_tag(callee);
    if (kind != NODE_VAR_ACCESS && kind != NODE_FIELD_ACCESS) { return 0; }
    let name: String = format_ast_path(ref source, callee);
    let target: Int = get_builtin_cast_target(name);
    if (target != 0) { return target; }
    if (source.named_types is null || source.current_file_type_aliases is null || source.global_type_aliases is null) { return 0; }
    return get_cast_target(ref source, name);
}

func wir_cast_needs_check(ref source: Compiler, source_type: Int, target_type: Int) -> Bool {
    if (source_type == target_type) { return false; }
    source_type = get_repr_type(ref source, source_type);
    target_type = get_repr_type(ref source, target_type);
    if (source_type == TYPE_ANY_ERROR) { source_type = TYPE_INT; }
    if (source.struct_id_map is !null) {
        let info: StructInfo = source.struct_id_map.lookup("" + source_type);
        if (has_struct(info) && info.is_enum) { source_type = TYPE_INT; }
    }
    if (target_type == TYPE_BOOL) { return source_type != TYPE_BOOL; }
    if (target_type == TYPE_CHAR) { return source_type != TYPE_CHAR && source_type != TYPE_BOOL; }
    if (source_type == TYPE_BOOL) { return false; }

    let source_float: Bool = source_type == TYPE_FLOAT || source_type == TYPE_FLOAT32;
    if (source_float && is_integer_type(target_type)) { return true; }
    if (!is_integer_type(source_type) || !is_integer_type(target_type)) { return false; }
    let source_bits: Int = get_type_bitwidth(source_type);
    let target_bits: Int = get_type_bitwidth(target_type);
    let source_unsigned: Bool = is_unsigned_integer(source_type);
    let target_unsigned: Bool = is_unsigned_integer(target_type);
    if (source_unsigned == target_unsigned) { return source_bits > target_bits; }
    if (source_unsigned) { return source_bits >= target_bits; }
    return true;
}

func wir_power_of_two(bits: Int) -> UInt128 {
    let value: UInt128 = UInt128(1U);
    let i: Int = 0;
    while (i < bits) {
        value <<= 1;
        i++;
    }
    return value;
}

func wir_integer_max(type_id: Int) -> UInt128 {
    let bits: Int = get_type_bitwidth(type_id);
    if (is_signed_integer(type_id)) { return wir_power_of_two(bits - 1) - UInt128(1U); }
    if (bits == 128) { return 340282366920938463463374607431768211455ULL; }
    return wir_power_of_two(bits) - UInt128(1U);
}

func wir_negative_bits(source_bits: Int, magnitude: UInt128) -> UInt128 {
    let mask: UInt128 = 340282366920938463463374607431768211455ULL;
    if (source_bits < 128) { mask = wir_power_of_two(source_bits) - UInt128(1U); }
    return mask - magnitude + UInt128(1U);
}

func wir_float_power_of_two(bits: Int) -> Float {
    let value: Float = 1.0;
    let i: Int = 0;
    while (i < bits) {
        value *= 2.0;
        i++;
    }
    return value;
}

func wir_bool_and(ref program: WirModule, block: WirBlockID, left: WirValueID, right: WirValueID) -> WirValueID {
    if (left == NO_WIR_VALUE) { return right; }
    return wir_binary(ref program, block, WirOpcode.BitAnd, program.bool_type, left, right, "", no_wir_location());
}

func wir_bool_or(ref program: WirModule, block: WirBlockID, left: WirValueID, right: WirValueID) -> WirValueID {
    return wir_binary(ref program, block, WirOpcode.BitOr, program.bool_type, left, right, "", no_wir_location());
}

func wir_integer_cast_condition(ref state: WirFunctionLowering, ref source: Compiler, ref program: WirModule, value: WirExpr, target_type: Int) -> WirValueID {
    let source_type: Int = get_repr_type(ref source, value.source_type);
    target_type = get_repr_type(ref source, target_type);
    let value_type: WirTypeID = wir_value_type(program, value.value);
    let source_bits: Int = get_type_bitwidth(source_type);
    let target_bits: Int = get_type_bitwidth(target_type);
    let source_signed: Bool = is_signed_integer(source_type);
    let source_unsigned: Bool = is_unsigned_integer(source_type) || source_type == TYPE_BOOL;
    let target_unsigned: Bool = is_unsigned_integer(target_type);
    let zero: WirValueID = wir_const_int(ref program, value_type, UInt128(0U));
    let valid: WirValueID = NO_WIR_VALUE;

    if (target_type == TYPE_BOOL) {
        let one: WirValueID = wir_const_int(ref program, value_type, UInt128(1U));
        let is_zero: WirValueID = wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, value.value, zero, "", no_wir_location());
        let is_one: WirValueID = wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, value.value, one, "", no_wir_location());
        return wir_bool_or(ref program, state.block, is_zero, is_one);
    }

    if (target_type == TYPE_CHAR) {
        if (source_signed) {
            let non_negative: WirValueID = wir_binary(ref program, state.block, WirOpcode.SignedGreaterEqual, program.bool_type, value.value, zero, "", no_wir_location());
            valid = wir_bool_and(ref program, state.block, valid, non_negative);
        }
        if (source_bits >= 32) {
            let limit: WirValueID = wir_const_int(ref program, value_type, UInt128(1114111U));
            let opcode: WirOpcode = WirOpcode.UnsignedLessEqual;
            if (source_signed) { opcode = WirOpcode.SignedLessEqual; }
            let below_limit: WirValueID = wir_binary(ref program, state.block, opcode, program.bool_type, value.value, limit, "", no_wir_location());
            valid = wir_bool_and(ref program, state.block, valid, below_limit);
        }
        if (source_bits >= 32 || (source_unsigned && source_bits >= 16)) {
            let low: WirValueID = wir_const_int(ref program, value_type, UInt128(55296U));
            let high: WirValueID = wir_const_int(ref program, value_type, UInt128(57343U));
            let less: WirOpcode = WirOpcode.UnsignedLess;
            let greater: WirOpcode = WirOpcode.UnsignedGreater;
            if (source_signed) {
                less = WirOpcode.SignedLess;
                greater = WirOpcode.SignedGreater;
            }
            let below: WirValueID = wir_binary(ref program, state.block, less, program.bool_type, value.value, low, "", no_wir_location());
            let above: WirValueID = wir_binary(ref program, state.block, greater, program.bool_type, value.value, high, "", no_wir_location());
            valid = wir_bool_and(ref program, state.block, valid, wir_bool_or(ref program, state.block, below, above));
        }
        if (valid == NO_WIR_VALUE) { return wir_const_bool(ref program, true); }
        return valid;
    }

    if (source_signed && target_unsigned) {
        let non_negative: WirValueID = wir_binary(ref program, state.block, WirOpcode.SignedGreaterEqual, program.bool_type, value.value, zero, "", no_wir_location());
        valid = wir_bool_and(ref program, state.block, valid, non_negative);
        if (target_bits < source_bits) {
            let maximum: WirValueID = wir_const_int(ref program, value_type, wir_integer_max(target_type));
            let below_max: WirValueID = wir_binary(ref program, state.block, WirOpcode.SignedLessEqual, program.bool_type, value.value, maximum, "", no_wir_location());
            valid = wir_bool_and(ref program, state.block, valid, below_max);
        }
    } else if (source_unsigned && !target_unsigned) {
        let maximum: WirValueID = wir_const_int(ref program, value_type, wir_integer_max(target_type));
        valid = wir_binary(ref program, state.block, WirOpcode.UnsignedLessEqual, program.bool_type, value.value, maximum, "", no_wir_location());
    } else if (source_bits > target_bits) {
        let maximum: WirValueID = wir_const_int(ref program, value_type, wir_integer_max(target_type));
        let upper: WirOpcode = WirOpcode.UnsignedLessEqual;
        if (source_signed) { upper = WirOpcode.SignedLessEqual; }
        valid = wir_binary(ref program, state.block, upper, program.bool_type, value.value, maximum, "", no_wir_location());
        if (source_signed) {
            let minimum_magnitude: UInt128 = wir_power_of_two(target_bits - 1);
            let minimum: WirValueID = wir_const_int(ref program, value_type, wir_negative_bits(source_bits, minimum_magnitude));
            let above_min: WirValueID = wir_binary(ref program, state.block, WirOpcode.SignedGreaterEqual, program.bool_type, value.value, minimum, "", no_wir_location());
            valid = wir_bool_and(ref program, state.block, valid, above_min);
        }
    }
    if (valid == NO_WIR_VALUE) { return wir_const_bool(ref program, true); }
    return valid;
}

func wir_float_cast_condition(ref state: WirFunctionLowering, ref source: Compiler, ref program: WirModule, value: WirExpr, target_type: Int) -> WirValueID {
    target_type = get_repr_type(ref source, target_type);
    let value_type: WirTypeID = wir_value_type(program, value.value);
    if (target_type == TYPE_BOOL) {
        let zero: WirValueID = wir_const_float(ref program, value_type, 0.0);
        let one: WirValueID = wir_const_float(ref program, value_type, 1.0);
        let is_zero: WirValueID = wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, value.value, zero, "", no_wir_location());
        let is_one: WirValueID = wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, value.value, one, "", no_wir_location());
        return wir_bool_or(ref program, state.block, is_zero, is_one);
    }

    let bound_bits: Int = get_type_bitwidth(target_type);
    if (is_signed_integer(target_type)) { bound_bits--; }
    let lower_value: Float = 0.0;
    let upper_value: Float = wir_float_power_of_two(bound_bits);
    if (is_signed_integer(target_type)) { lower_value = 0.0 - upper_value; }
    if (target_type == TYPE_CHAR) {
        lower_value = 0.0;
        upper_value = 1114112.0;
    }
    let lower: WirValueID = wir_const_float(ref program, value_type, lower_value);
    let upper: WirValueID = wir_const_float(ref program, value_type, upper_value);
    let above_min: WirValueID = wir_binary(ref program, state.block, WirOpcode.FloatGreaterEqual, program.bool_type, value.value, lower, "", no_wir_location());
    let below_max: WirValueID = wir_binary(ref program, state.block, WirOpcode.FloatLess, program.bool_type, value.value, upper, "", no_wir_location());
    let valid: WirValueID = wir_bool_and(ref program, state.block, above_min, below_max);
    if (target_type != TYPE_CHAR) { return valid; }

    let surrogate_start: WirValueID = wir_const_float(ref program, value_type, 55296.0);
    let surrogate_end: WirValueID = wir_const_float(ref program, value_type, 57344.0);
    let before: WirValueID = wir_binary(ref program, state.block, WirOpcode.FloatLess, program.bool_type, value.value, surrogate_start, "", no_wir_location());
    let after: WirValueID = wir_binary(ref program, state.block, WirOpcode.FloatGreaterEqual, program.bool_type, value.value, surrogate_end, "", no_wir_location());
    return wir_bool_and(ref program, state.block, valid, wir_bool_or(ref program, state.block, before, after));
}

func wir_cast_condition(ref state: WirFunctionLowering, ref source: Compiler, ref program: WirModule, value: WirExpr, target_type: Int) -> WirValueID {
    let source_type: Int = get_repr_type(ref source, value.source_type);
    if (source_type == TYPE_FLOAT || source_type == TYPE_FLOAT32) {
        return wir_float_cast_condition(ref state, ref source, ref program, value, target_type);
    }
    return wir_integer_cast_condition(ref state, ref source, ref program, value, target_type);
}

func wir_guard_cast(ref state: WirFunctionLowering, ref program: WirModule, valid: WirValueID) -> Void {
    let success: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "cast.ok."), []);
    let failure: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "cast.fail."), []);
    wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [valid], [wir_edge(success, []), wir_edge(failure, [])], no_wir_location());
    state.block = failure;
    wir_trap(ref program, state.block, no_wir_location());
    state.block = success;
}

func wir_copy_owned(values: Vector(WirOwnedValue)) -> Vector(WirOwnedValue) {
    let copy: Vector(WirOwnedValue) = [];
    let i: Int = 0;
    while (i < values.length()) {
        copy.append(values[i]);
        i++;
    }
    return copy;
}

func wir_copy_bindings(values: Vector(WirBinding)) -> Vector(WirBinding) {
    let copy: Vector(WirBinding) = [];
    let i: Int = 0;
    while (i < values.length()) {
        copy.append(values[i]);
        i++;
    }
    return copy;
}

func wir_pop_error_target(ref state: WirFunctionLowering) -> Void {
    let targets: Vector(WirErrorTarget) = [];
    let i: Int = 0;
    while (i + 1 < state.error_targets.length()) {
        targets.append(state.error_targets[i]);
        i++;
    }
    state.error_targets = targets;
}

func wir_make_error_result(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, block: WirBlockID, source_type: Int, error_value: WirValueID) -> WirValueID {
    let fallible_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
    if (fallible_type == NO_WIR_TYPE) { return NO_WIR_VALUE; }
    let fields: Vector(WirValueID) = [wir_const_bool(ref program, true), error_value];
    let inner_type: Int = get_inner_fallible_type(ref source, source_type);
    if (inner_type != TYPE_VOID) {
        let inner: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, inner_type);
        if (inner == NO_WIR_TYPE) { return NO_WIR_VALUE; }
        fields.append(wir_const_zero(ref program, inner));
    }
    return wir_struct_value(ref program, block, fallible_type, fields, "", no_wir_location());
}

func wir_make_success_result(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, block: WirBlockID, source_type: Int, value: WirExpr) -> WirValueID {
    let fallible_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
    if (fallible_type == NO_WIR_TYPE) { return NO_WIR_VALUE; }
    let error_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, TYPE_ANY_ERROR);
    if (error_type == NO_WIR_TYPE) { return NO_WIR_VALUE; }
    let fields: Vector(WirValueID) = [wir_const_bool(ref program, false), wir_const_zero(ref program, error_type)];
    let inner_type: Int = get_inner_fallible_type(ref source, source_type);
    if (inner_type != TYPE_VOID) {
        if (value.value == NO_WIR_VALUE) { return NO_WIR_VALUE; }
        fields.append(value.value);
    }
    return wir_struct_value(ref program, block, fallible_type, fields, "", no_wir_location());
}

func wir_error_result(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, error_value: WirValueID) -> WirValueID {
    return wir_make_error_result(ref types, ref source, ref program, state.block, state.return_type, error_value);
}

func wir_success_result(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirExpr) -> WirValueID {
    return wir_make_success_result(ref types, ref source, ref program, state.block, state.return_type, value);
}

func wir_error_value(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirExpr) -> WirValueID {
    if (value.source_type == TYPE_ANY_ERROR) { return value.value; }
    let error_type: Int = get_repr_type(ref source, value.source_type);
    if (!is_error_type(ref source, error_type)) {
        state.errors.append("throw reached WIR lowering with a non-error value");
        return NO_WIR_VALUE;
    }
    let layout: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, TYPE_ANY_ERROR);
    let domain_type: WirTypeID = wir_unsigned_int_type(ref program, 64);
    let domain: WirValueID = wir_const_int(ref program, domain_type, UInt128(type_fingerprint(ref source, error_type)));
    return wir_struct_value(ref program, state.block, layout, [domain, value.value], "", no_wir_location());
}

func wir_overflow_error(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule) -> WirValueID {
    let i: Int = 0;
    while (source.error_types is !null && i < source.error_types.length()) {
        let info: StructInfo = source.error_types[i];
        if (info.compiler_link_name == "Error") {
            let field: FieldInfo = find_field(info, "Overflow");
            if (has_field(field)) {
                let enum_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, info.type_id);
                if (enum_type == NO_WIR_TYPE) { return NO_WIR_VALUE; }
                let value: WirValueID = wir_const_int(ref program, enum_type, UInt128(field.offset));
                return wir_error_value(ref state, ref types, ref source, ref program, WirExpr(value=value, source_type=info.type_id));
            }
        }
        i++;
    }
    state.errors.append("standard Error enum has no Overflow member in WIR lowering");
    return NO_WIR_VALUE;
}

func wir_lower_fallible_cast(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirExpr, target_type: Int, valid: WirValueID) -> WirExpr {
    let source_type: Int = get_fallible_type_id(ref source, target_type);
    let result_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
    if (result_type == NO_WIR_TYPE) { return wir_no_expr(); }

    let success: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "cast.ok."), []);
    let failure: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "cast.fail."), []);
    let merge: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "cast.end."), [wir_param("value", result_type)]);
    wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [valid], [wir_edge(success, []), wir_edge(failure, [])], no_wir_location());

    state.block = failure;
    let error_value: WirValueID = wir_overflow_error(ref state, ref types, ref source, ref program);
    if (error_value == NO_WIR_VALUE) { return wir_no_expr(); }
    let failed: WirValueID = wir_make_error_result(ref types, ref source, ref program, state.block, source_type, error_value);
    if (failed == NO_WIR_VALUE) { return wir_no_expr(); }
    wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(merge, [failed])], no_wir_location());

    state.block = success;
    let converted: WirExpr = wir_cast_expr(ref state, ref types, ref source, ref program, value, target_type, false);
    if (converted.value == NO_WIR_VALUE) { return wir_no_expr(); }
    let succeeded: WirValueID = wir_make_success_result(ref types, ref source, ref program, state.block, source_type, converted);
    if (succeeded == NO_WIR_VALUE) { return wir_no_expr(); }
    wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(merge, [succeeded])], no_wir_location());

    state.block = merge;
    let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(merge))];
    return WirExpr(value=block.parameters[0], source_type=source_type);
}

func wir_lower_throw(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: ThrowNode) -> Void {
    let value: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, node.value);
    if (value.value == NO_WIR_VALUE) { return; }
    let error_value: WirValueID = wir_error_value(ref state, ref types, ref source, ref program, value);
    if (error_value == NO_WIR_VALUE) { return; }
    wir_route_error(ref state, ref types, ref source, ref program, error_value);
}

func wir_route_error(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, error_value: WirValueID) -> Void {
    if (state.error_targets.length() != 0) {
        let target: WirErrorTarget = state.error_targets[state.error_targets.length() - 1];
        wir_cleanup_temporaries(ref state, ref source, ref program, target.owned_count);
        wir_cleanup_bindings(ref state, ref source, ref program, target.binding_count);
        wir_store(ref program, state.block, error_value, target.address, no_wir_location());
        wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(target.block, [])], no_wir_location());
        state.terminated = true;
        return;
    }
    if (is_fallible_type(ref source, state.return_type)) {
        let result: WirValueID = wir_error_result(ref state, ref types, ref source, ref program, error_value);
        if (result == NO_WIR_VALUE) {
            state.errors.append("failed to build a fallible error result in WIR lowering");
            wir_trap(ref program, state.block, no_wir_location());
        } else {
            wir_cleanup_temporaries(ref state, ref source, ref program, 0);
            wir_cleanup_bindings(ref state, ref source, ref program, 0);
            wir_return(ref program, state.block, result, no_wir_location());
        }
        state.terminated = true;
        return;
    }
    state.errors.append("fallible value reached WIR lowering without a catch or fallible return type");
    wir_trap(ref program, state.block, no_wir_location());
    state.terminated = true;
}

func wir_lower_try_unwrap(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: TryUnwrapNode) -> WirExpr {
    let value: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, node.expr);
    if (value.value == NO_WIR_VALUE) { return wir_no_expr(); }
    if (!is_fallible_type(ref source, value.source_type)) {
        state.errors.append("try unwrap reached WIR lowering with a non-fallible value");
        return wir_no_expr();
    }

    let inner_type: Int = get_inner_fallible_type(ref source, value.source_type);
    let is_error: WirValueID = wir_field(ref program, state.block, value.value, 0, "", no_wir_location());
    let error_value: WirValueID = wir_field(ref program, state.block, value.value, 1, "", no_wir_location());
    let failure: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "error."), []);
    let success: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "unwrap."), []);
    wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [is_error], [wir_edge(failure, []), wir_edge(success, [])], no_wir_location());

    let saved_owned: Vector(WirOwnedValue) = wir_copy_owned(state.owned_values);
    let owns_result: Bool = wir_take_owned(ref state, value.value);
    state.block = failure;
    state.terminated = false;
    wir_route_error(ref state, ref types, ref source, ref program, error_value);

    state.owned_values = saved_owned;
    if (owns_result) { wir_take_owned(ref state, value.value); }
    state.block = success;
    state.terminated = false;
    if (inner_type == TYPE_VOID) { return WirExpr(value=NO_WIR_VALUE, source_type=TYPE_VOID); }
    let result: WirValueID = wir_field(ref program, state.block, value.value, 2, "", no_wir_location());
    if (owns_result && wir_value_needs_drop(ref source, inner_type)) { wir_track_owned(ref state, result, inner_type); }
    return WirExpr(value=result, source_type=inner_type);
}

func wir_lower_catch(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: CatchNode) -> Void {
    let parent_binding_count: Int = state.bindings.length();
    let parent_owned: Vector(WirOwnedValue) = wir_copy_owned(state.owned_values);
    let error_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, TYPE_ANY_ERROR);
    if (error_type == NO_WIR_TYPE) { return; }
    let error_address: WirValueID = wir_stack_alloc(ref program, state.entry, error_type, node.err_name.value + ".addr", no_wir_location());
    let failure: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "catch."), []);
    let merge: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "catch.end."), []);
    state.error_targets.append(WirErrorTarget(block=failure, address=error_address, binding_count=parent_binding_count, owned_count=state.owned_values.length()));

    wir_lower_stmt(ref state, ref types, ref source, ref program, node.stmt);
    let normal_end: WirBlockID = state.block;
    let normal_terminated: Bool = state.terminated;
    let normal_bindings: Vector(WirBinding) = wir_copy_bindings(state.bindings);
    let normal_owned: Vector(WirOwnedValue) = wir_copy_owned(state.owned_values);
    wir_pop_error_target(ref state);
    if (!normal_terminated) { wir_append(ref program, normal_end, WirOpcode.Jump, program.void_type, [], [wir_edge(merge, [])], no_wir_location()); }

    wir_restore_bindings(ref state, parent_binding_count);
    state.owned_values = wir_copy_owned(parent_owned);
    state.bindings.append(WirBinding(name=node.err_name.value, source_type=TYPE_ANY_ERROR, address=error_address, is_const=false, owns_value=false));
    state.block = failure;
    state.terminated = false;
    wir_lower_block(ref state, ref types, ref source, ref program, node.body);
    let catch_end: WirBlockID = state.block;
    let catch_terminated: Bool = state.terminated;
    let catch_owned: Vector(WirOwnedValue) = wir_copy_owned(state.owned_values);
    if (!catch_terminated) { wir_append(ref program, catch_end, WirOpcode.Jump, program.void_type, [], [wir_edge(merge, [])], no_wir_location()); }

    if (normal_terminated && catch_terminated) {
        state.terminated = true;
        return;
    }
    state.block = merge;
    state.terminated = false;
    if (!normal_terminated) {
        state.bindings = normal_bindings;
        state.owned_values = normal_owned;
    } else {
        wir_restore_bindings(ref state, parent_binding_count);
        state.owned_values = catch_owned;
    }
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

func wir_unbox_variant(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirExpr, target_type: Int) -> WirExpr {
    let variant: StructInfo = source.struct_id_map.lookup("" + get_repr_type(ref source, value.source_type));
    if (!has_struct(variant) || variant.name != "$Variant") { return wir_no_expr(); }

    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [value.value], [], no_wir_location());
    let tag_slot: WirValueID = wir_field_address(ref program, state.block, value.value, 0, "", no_wir_location());
    let tag: WirValueID = wir_load(ref program, state.block, tag_slot, "", no_wir_location());
    let tag_type: WirTypeID = wir_unsigned_int_type(ref program, 64);
    let expected_tag: WirValueID = wir_const_int(ref program, tag_type, UInt128(type_fingerprint(ref source, target_type)));
    let matches: WirValueID = wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, tag, expected_tag, "", no_wir_location());
    wir_guard_cast(ref state, ref program, matches);

    let low_slot: WirValueID = wir_field_address(ref program, state.block, value.value, 1, "", no_wir_location());
    let low: WirValueID = wir_load(ref program, state.block, low_slot, "", no_wir_location());
    let target_wir: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, target_type);
    if (target_wir == NO_WIR_TYPE) { return wir_no_expr(); }
    let target_kind: WirTypeKind = program.arena.types[wir_id_index(UInt32(target_wir))].kind;
    if (target_kind == WirTypeKind.Pointer) {
        return WirExpr(value=wir_cast(ref program, state.block, low, target_wir, "", no_wir_location()), source_type=target_type);
    }
    if ((target_kind == WirTypeKind.BoolType || target_kind == WirTypeKind.SignedInt || target_kind == WirTypeKind.UnsignedInt) && program.arena.types[wir_id_index(UInt32(target_wir))].bits <= 64) {
        return WirExpr(value=wir_cast(ref program, state.block, low, target_wir, "", no_wir_location()), source_type=target_type);
    }
    if (target_type == TYPE_FLOAT) {
        return WirExpr(value=wir_unary(ref program, state.block, WirOpcode.Bitcast, target_wir, low, "", no_wir_location()), source_type=target_type);
    }
    state.errors.append("Variant payload for " + get_type_name(ref source, target_type) + " is not lowered to WIR yet");
    return wir_no_expr();
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
    if (has_struct(source_info) && source_info.name == "$Variant") {
        return wir_unbox_variant(ref state, ref types, ref source, ref program, value, target_type);
    }
    let source_wir: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, value.source_type);
    let target_wir: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, target_type);
    if (source_wir == NO_WIR_TYPE || target_wir == NO_WIR_TYPE) { return wir_no_expr(); }
    let source_kind: WirTypeKind = program.arena.types[wir_id_index(UInt32(source_wir))].kind;
    let target_kind: WirTypeKind = program.arena.types[wir_id_index(UInt32(target_wir))].kind;
    let source_integer: Bool = source_kind == WirTypeKind.BoolType || source_kind == WirTypeKind.SignedInt || source_kind == WirTypeKind.UnsignedInt;
    let target_integer: Bool = target_kind == WirTypeKind.BoolType || target_kind == WirTypeKind.SignedInt || target_kind == WirTypeKind.UnsignedInt;
    if (value.source_type == TYPE_NULLPTR) {
        if (!is_pointer_type(ref source, target_type)) {
            state.errors.append("nullptr reached WIR lowering with non-pointer target " + get_type_name(ref source, target_type));
            return wir_no_expr();
        }
        return WirExpr(value=wir_cast(ref program, state.block, value.value, target_wir, "", no_wir_location()), source_type=target_type);
    }
    if (value.source_type == TYPE_NULL) {
        if (is_pointer_type(ref source, target_type) || !is_nullable_reference_type(ref source, target_type)) {
            state.errors.append("null reached WIR lowering with non-reference target " + get_type_name(ref source, target_type));
            return wir_no_expr();
        }
        if (target_kind == WirTypeKind.Struct) {
            return WirExpr(value=wir_const_zero(ref program, target_wir), source_type=target_type);
        }
        return WirExpr(value=wir_cast(ref program, state.block, value.value, target_wir, "", no_wir_location()), source_type=target_type);
    }
    if (source_kind == WirTypeKind.Pointer && target_kind == WirTypeKind.Pointer) {
        let compatible: Bool = is_void_ptr(ref source, value.source_type) ||
                               is_void_ptr(ref source, target_type);
        if (implicit && !compatible) {
            state.errors.append("implicit pointer conversion from " + get_type_name(ref source, value.source_type) + " to " + get_type_name(ref source, target_type) + " reached WIR lowering");
            return wir_no_expr();
        }
        let casted: WirValueID = wir_cast(ref program, state.block, value.value, target_wir, "", no_wir_location());
        if (wir_take_owned(ref state, value.value)) { wir_track_owned(ref state, casted, target_type); }
        return WirExpr(value=casted, source_type=target_type);
    }
    if (!implicit && source_kind == WirTypeKind.Pointer && target_integer) {
        return WirExpr(value=wir_cast(ref program, state.block, value.value, target_wir, "", no_wir_location()), source_type=target_type);
    }
    if (!implicit && source_integer && target_kind == WirTypeKind.Pointer) {
        return WirExpr(value=wir_cast(ref program, state.block, value.value, target_wir, "", no_wir_location()), source_type=target_type);
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

func wir_identity_operand(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: NodeID) -> WirExpr {
    let value: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, node);
    if (value.value == NO_WIR_VALUE) { return wir_no_expr(); }

    let info: StructInfo = StructInfo();
    if (source.struct_id_map is !null) { info = source.struct_id_map.lookup("" + get_repr_type(ref source, value.source_type)); }
    if (has_struct(info) && info.is_interface) {
        return WirExpr(value=wir_field(ref program, state.block, value.value, 0, "", no_wir_location()), source_type=TYPE_ANYPTR);
    }

    let value_type: WirTypeID = wir_value_type(program, value.value);
    if (program.arena.types[wir_id_index(UInt32(value_type))].kind != WirTypeKind.Pointer) {
        state.errors.append("identity comparison reached WIR lowering with a non-reference operand");
        return wir_no_expr();
    }
    let pointer_type: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let pointer: WirValueID = value.value;
    if (value_type != pointer_type) { pointer = wir_cast(ref program, state.block, pointer, pointer_type, "", no_wir_location()); }
    return WirExpr(value=pointer, source_type=TYPE_ANYPTR);
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
        if (!has_struct(info) || info.is_enum) { return TYPE_POISON; }
        let field: FieldInfo = find_field(info, access.field_name);
        if (has_field(field)) { return field.type; }
        return TYPE_POISON;
    }
    if (kind == NODE_INDEX_ACCESS) {
        let access: IndexAccessNode = get_index_access_node(source.arena, node);
        let target_type: Int = get_repr_type(ref source, wir_lvalue_type(state, source, access.target));
        if (target_type == TYPE_STRING) { return TYPE_BYTE; }
        let pointer: SymbolInfo = source.ptr_base_map.lookup("" + target_type);
        if (has_symbol(pointer)) { return pointer.type; }
        let info: ArrayInfo = source.array_info_map.lookup("" + target_type);
        if (has_array_info(info)) { return info.base_type; }
        let vector: SymbolInfo = source.vector_base_map.lookup("" + target_type);
        if (has_symbol(vector)) { return vector.type; }
    }
    return TYPE_POISON;
}

func wir_enum_member(ref types: WirTypeMap, ref source: Compiler, node: FieldAccessNode) -> WirEnumValue {
    if (!has_node(node.obj)) { return WirEnumValue(); }
    let owner: String = format_ast_path(ref source, node.obj);
    if (owner == "<unknown_path>") { return WirEnumValue(); }
    let key: String = source.current_package_prefix + owner + "." + node.field_name;
    let value: WirEnumValue = types.enum_values.lookup(key);
    if (value.source_type != 0) { return value; }

    key = owner + "." + node.field_name;
    value = types.enum_values.lookup(key);
    if (value.source_type != 0) { return value; }

    let separator: Int = 0;
    while (separator < owner.length() && owner[separator] != '.') { separator++; }
    if (separator < owner.length() && source.current_file_visible_prefixes is !null) {
        let root: String = owner.slice(0, separator);
        let prefix: String = source.current_file_visible_prefixes.lookup(root);
        if (prefix is !null) {
            key = prefix + owner.slice(separator + 1, owner.length()) + "." + node.field_name;
            value = types.enum_values.lookup(key);
            if (value.source_type != 0) { return value; }
        }
    }

    if (source.current_file_type_aliases is !null) {
        let mapped: String = source.current_file_type_aliases.lookup(owner);
        if (mapped is !null) {
            value = types.enum_values.lookup(mapped + "." + node.field_name);
            if (value.source_type != 0) { return value; }
        }
    }
    if (source.global_type_aliases is !null) {
        let mapped: String = source.global_type_aliases.lookup(owner);
        if (mapped is !null) { return types.enum_values.lookup(mapped + "." + node.field_name); }
    }
    return WirEnumValue();
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
    if (!has_struct(info) || info.is_interface || info.is_enum) {
        state.errors.append("field '" + name + "' is not addressable in WIR lowering");
        return wir_no_expr();
    }
    let field: FieldInfo = find_field(info, name);
    if (!has_field(field)) {
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
    let target_type: Int = get_repr_type(ref source, wir_lvalue_type(state, source, target_node));
    let index: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, index_node);
    if (index.value == NO_WIR_VALUE) { return wir_no_expr(); }
    if (index.source_type != TYPE_INT) {
        state.errors.append("array index reached WIR lowering with a non-Int type");
        return wir_no_expr();
    }

    let pointer: SymbolInfo = source.ptr_base_map.lookup("" + target_type);
    if (has_symbol(pointer)) {
        if (pointer.type == TYPE_VOID) {
            state.errors.append("Void pointer reached WIR lowering with an index operation");
            return wir_no_expr();
        }
        let target: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, target_node);
        if (target.value == NO_WIR_VALUE) { return wir_no_expr(); }
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [target.value], [], no_wir_location());
        return WirExpr(value=wir_index_address(ref program, state.block, target.value, index.value, "", no_wir_location()), source_type=pointer.type);
    }

    let info: ArrayInfo = source.array_info_map.lookup("" + target_type);
    if (has_array_info(info)) {
        let target: WirExpr = wir_lower_lvalue(ref state, ref types, ref source, ref program, target_node);
        if (target.value == NO_WIR_VALUE) { return wir_no_expr(); }
        if (info.size >= 0) {
            let length: WirValueID = wir_const_int(ref program, wir_lower_source_type(ref types, ref source, ref program, TYPE_INT), UInt128(UInt32(info.size)));
            wir_append(ref program, state.block, WirOpcode.BoundsCheck, program.void_type, [index.value, length], [], no_wir_location());
            return WirExpr(value=wir_index_address(ref program, state.block, target.value, index.value, "", no_wir_location()), source_type=info.base_type);
        }

        let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
        let size_index: WirExpr = wir_cast_expr(ref state, ref types, ref source, ref program, index, TYPE_UINTSIZE, false);
        if (size_index.value == NO_WIR_VALUE) { return wir_no_expr(); }
        let start: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, target.value, 0, "", no_wir_location()), "", no_wir_location());
        let length: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, target.value, 1, "", no_wir_location()), "", no_wir_location());
        wir_append(ref program, state.block, WirOpcode.BoundsCheck, program.void_type, [size_index.value, length], [], no_wir_location());
        let absolute: WirValueID = wir_binary(ref program, state.block, WirOpcode.Add, size_type, start, size_index.value, "", no_wir_location());
        let data_slot: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, target.value, 3, "", no_wir_location()), "", no_wir_location());
        let size_slot: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, target.value, 4, "", no_wir_location()), "", no_wir_location());
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [data_slot], [], no_wir_location());
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [size_slot], [], no_wir_location());
        let owner_size: WirValueID = wir_load(ref program, state.block, size_slot, "", no_wir_location());
        wir_append(ref program, state.block, WirOpcode.BoundsCheck, program.void_type, [absolute, owner_size], [], no_wir_location());
        let data: WirValueID = wir_load(ref program, state.block, data_slot, "", no_wir_location());
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [data], [], no_wir_location());
        return WirExpr(value=wir_index_address(ref program, state.block, data, absolute, "", no_wir_location()), source_type=info.base_type);
    }

    let vector: SymbolInfo = source.vector_base_map.lookup("" + target_type);
    if (has_symbol(vector)) {
        let target: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, target_node);
        if (target.value == NO_WIR_VALUE) { return wir_no_expr(); }
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [target.value], [], no_wir_location());
        let size_index: WirExpr = wir_cast_expr(ref state, ref types, ref source, ref program, index, TYPE_UINTSIZE, false);
        if (size_index.value == NO_WIR_VALUE) { return wir_no_expr(); }
        let length: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, target.value, 0, "", no_wir_location()), "", no_wir_location());
        wir_append(ref program, state.block, WirOpcode.BoundsCheck, program.void_type, [size_index.value, length], [], no_wir_location());
        let data: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, target.value, 2, "", no_wir_location()), "", no_wir_location());
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [data], [], no_wir_location());
        return WirExpr(value=wir_index_address(ref program, state.block, data, size_index.value, "", no_wir_location()), source_type=vector.type);
    }

    state.errors.append("type is not addressable through an index in WIR lowering");
    return wir_no_expr();
}

func wir_lower_index_expr(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, access: IndexAccessNode) -> WirExpr {
    let target_type: Int = get_repr_type(ref source, wir_lvalue_type(state, source, access.target));
    if (target_type == TYPE_STRING) {
        let target: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, access.target);
        let index: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, access.index_node);
        if (target.value == NO_WIR_VALUE || index.value == NO_WIR_VALUE) { return wir_no_expr(); }
        if (index.source_type != TYPE_INT) {
            state.errors.append("String index reached WIR lowering with a non-Int type");
            return wir_no_expr();
        }
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [target.value], [], no_wir_location());
        let data: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, target.value, 0, "", no_wir_location()), "", no_wir_location());
        let length: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, target.value, 1, "", no_wir_location()), "", no_wir_location());
        wir_append(ref program, state.block, WirOpcode.BoundsCheck, program.void_type, [index.value, length], [], no_wir_location());
        return WirExpr(value=wir_load(ref program, state.block, wir_index_address(ref program, state.block, data, index.value, "", no_wir_location()), "", no_wir_location()), source_type=TYPE_BYTE);
    }

    let address: WirExpr = wir_lower_index_lvalue(ref state, ref types, ref source, ref program, access.target, access.index_node);
    if (address.value == NO_WIR_VALUE) { return wir_no_expr(); }
    return WirExpr(value=wir_load(ref program, state.block, address.value, "", no_wir_location()), source_type=address.source_type);
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
        let global: WirSourceGlobal = wir_direct_global(ref state, ref source, node);
        if (has_wir_source_global(global)) {
            let global_id: WirGlobalID = wir_find_global(program, global.name);
            if (global_id == NO_WIR_GLOBAL) {
                state.errors.append("global '" + global.name + "' was not declared before WIR lowering");
                return wir_no_expr();
            }
            return WirExpr(value=wir_global_value(program, global_id), source_type=global.source_type);
        }
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
    let vector: SymbolInfo = SymbolInfo();
    if (source.vector_base_map is !null) { vector = source.vector_base_map.lookup("" + source_type); }
    if (has_symbol(vector)) {
        return wir_lower_vector_literal(ref state, ref types, ref source, ref program, node, source_type, vector.type);
    }
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
        if ((argument.name is !null && argument.name.length() != 0) || argument.is_spread) {
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
        if (argument.name is !null && argument.name.length() != 0) {
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

func wir_vector_drop_name(source_type: Int) -> String {
    return "__wl_drop." + source_type;
}

func wir_vector_drop_function(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, source_type: Int, element_type: Int) -> WirFuncID {
    let name: String = wir_vector_drop_name(source_type);
    let function_id: WirFuncID = wir_find_function(program, name);
    if (function_id != NO_WIR_FUNC) { return function_id; }

    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    function_id = wir_add_function(ref program, name, [wir_param("object", raw_pointer)], program.void_type, false, WirLinkage.Internal, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let vector_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
    let object: WirValueID = wir_cast(ref program, entry, function.parameters[0], vector_type, "", no_wir_location());
    let state: WirFunctionLowering = WirFunctionLowering(function=function_id, return_type=TYPE_VOID, entry=entry, block=entry, bindings=[], loops=[], error_targets=[], owned_values=[], errors=[], terminated=false, next_block=0);
    let data: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, object, 2, "", no_wir_location()), "", no_wir_location());

    if (wir_value_needs_drop(ref source, element_type)) {
        let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
        let index_slot: WirValueID = wir_stack_alloc(ref program, entry, size_type, "index.addr", no_wir_location());
        wir_store(ref program, entry, wir_const_int(ref program, size_type, UInt128(0U)), index_slot, no_wir_location());
        let condition: WirBlockID = wir_add_block(ref program, function_id, "drop.cond", []);
        let body: WirBlockID = wir_add_block(ref program, function_id, "drop.body", []);
        let finish: WirBlockID = wir_add_block(ref program, function_id, "drop.end", []);
        wir_append(ref program, entry, WirOpcode.Jump, program.void_type, [], [wir_edge(condition, [])], no_wir_location());

        state.block = condition;
        let index: WirValueID = wir_load(ref program, condition, index_slot, "", no_wir_location());
        let length: WirValueID = wir_load(ref program, condition, wir_field_address(ref program, condition, object, 0, "", no_wir_location()), "", no_wir_location());
        let more: WirValueID = wir_binary(ref program, condition, WirOpcode.UnsignedLess, program.bool_type, index, length, "", no_wir_location());
        wir_append(ref program, condition, WirOpcode.Branch, program.void_type, [more], [wir_edge(body, []), wir_edge(finish, [])], no_wir_location());

        state.block = body;
        let element_address: WirValueID = wir_index_address(ref program, body, data, index, "", no_wir_location());
        let element: WirValueID = wir_load(ref program, body, element_address, "", no_wir_location());
        wir_emit_ownership_value(ref state, ref source, ref program, element, element_type, false);
        let one: WirValueID = wir_const_int(ref program, size_type, UInt128(1U));
        let next: WirValueID = wir_binary(ref program, state.block, WirOpcode.Add, size_type, index, one, "", no_wir_location());
        wir_store(ref program, state.block, next, index_slot, no_wir_location());
        wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(condition, [])], no_wir_location());
        state.block = finish;
    }

    let deallocator: FuncInfo = wir_compiler_link_function(ref source, "memory_free");
    if (!has_func(deallocator)) {
        types.errors.append("Vector drop glue requires the memory_free compiler link");
    } else {
        let deallocator_id: WirFuncID = wir_find_function(program, deallocator.name);
        if (deallocator_id == NO_WIR_FUNC) { deallocator_id = wir_lower_function_decl(ref types, ref source, ref program, deallocator); }
        if (deallocator_id != NO_WIR_FUNC) {
            let raw_data: WirValueID = wir_cast(ref program, state.block, data, raw_pointer, "", no_wir_location());
            wir_call(ref program, state.block, wir_function_value(program, deallocator_id), [raw_data], "", no_wir_location());
        }
    }
    let error_index: Int = 0;
    while (error_index < state.errors.length()) {
        types.errors.append(state.errors[error_index]);
        error_index++;
    }
    wir_return(ref program, state.block, NO_WIR_VALUE, no_wir_location());
    return function_id;
}

func wir_lower_vector_literal(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: NodeID, source_type: Int, element_type: Int) -> WirExpr {
    let literal: VectorLitNode = get_vector_lit_node(source.arena, node);
    let vector_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
    if (vector_type == NO_WIR_TYPE) { return wir_no_expr(); }
    let pointer: WirType = program.arena.types[wir_id_index(UInt32(vector_type))];
    if (pointer.kind != WirTypeKind.Pointer) {
        state.errors.append("Vector target has no pointer representation in WIR lowering");
        return wir_no_expr();
    }
    let payload: WirTypeLayout = wir_type_layout(program, pointer.element);
    let element_wir: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, element_type);
    let element_layout: WirTypeLayout = wir_type_layout(program, element_wir);
    if (!payload.valid || !element_layout.valid || element_layout.size == 0UL) {
        state.errors.append("Vector layout is unavailable during WIR lowering");
        return wir_no_expr();
    }

    let allocator: FuncInfo = wir_compiler_link_function(ref source, "memory_alloc");
    if (!has_func(allocator)) {
        state.errors.append("Vector construction requires the memory_alloc compiler link");
        return wir_no_expr();
    }
    let allocator_id: WirFuncID = wir_find_function(program, allocator.name);
    if (allocator_id == NO_WIR_FUNC) { allocator_id = wir_lower_function_decl(ref types, ref source, ref program, allocator); }
    if (allocator_id == NO_WIR_FUNC) { return wir_no_expr(); }

    let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
    let object_size: UInt64 = payload.size + UInt64(WIR_OBJECT_HEADER_SIZE);
    let raw: WirValueID = wir_call(ref program, state.block, wir_function_value(program, allocator_id), [wir_const_int(ref program, size_type, UInt128(object_size))], "", no_wir_location());
    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [raw], [], no_wir_location());

    let allocation_count: Int = literal.elements.length();
    if (allocation_count == 0) { allocation_count = 1; }
    let data_size: UInt64 = UInt64(allocation_count) * element_layout.size;
    let raw_data: WirValueID = wir_call(ref program, state.block, wir_function_value(program, allocator_id), [wir_const_int(ref program, size_type, UInt128(data_size))], "", no_wir_location());
    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [raw_data], [], no_wir_location());

    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let drop_id: WirFuncID = wir_vector_drop_function(ref types, ref source, ref program, source_type, element_type);
    let drop_address: WirValueID = wir_const_address(ref program, raw_pointer, wir_function_value(program, drop_id), 0L);
    let drop_slot: WirValueID = wir_cast(ref program, state.block, raw, wir_pointer_type(ref program, raw_pointer), "", no_wir_location());
    wir_store(ref program, state.block, drop_address, drop_slot, no_wir_location());

    let uint32_type: WirTypeID = wir_unsigned_int_type(ref program, 32);
    let refcount_slot: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE + WIR_ARC_REFCOUNT_OFFSET, wir_pointer_type(ref program, uint32_type));
    let type_slot: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE + WIR_ARC_TYPE_OFFSET, wir_pointer_type(ref program, uint32_type));
    wir_store(ref program, state.block, wir_const_int(ref program, uint32_type, UInt128(0U)), refcount_slot, no_wir_location());
    wir_store(ref program, state.block, wir_const_int(ref program, uint32_type, UInt128(UInt32(source_type))), type_slot, no_wir_location());

    let vector: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE, vector_type);
    let count: WirValueID = wir_const_int(ref program, size_type, UInt128(UIntSize(literal.elements.length())));
    wir_store(ref program, state.block, count, wir_field_address(ref program, state.block, vector, 0, "", no_wir_location()), no_wir_location());
    wir_store(ref program, state.block, count, wir_field_address(ref program, state.block, vector, 1, "", no_wir_location()), no_wir_location());
    let data_type: WirTypeID = program.arena.types[wir_id_index(UInt32(pointer.element))].fields[2];
    let data: WirValueID = wir_cast(ref program, state.block, raw_data, data_type, "", no_wir_location());
    wir_store(ref program, state.block, data, wir_field_address(ref program, state.block, vector, 2, "", no_wir_location()), no_wir_location());

    let i: Int = 0;
    while (i < literal.elements.length()) {
        let argument: ArgNode = literal.elements[i];
        if ((argument.name is !null && argument.name.length() != 0) || argument.is_spread) {
            state.errors.append("Vector literal contains a named or spread element in WIR lowering");
            return wir_no_expr();
        }
        let element: WirExpr = wir_lower_expected_expr(ref state, ref types, ref source, ref program, argument.val, element_type);
        if (element.value == NO_WIR_VALUE) { return wir_no_expr(); }
        element = wir_cast_expr(ref state, ref types, ref source, ref program, element, element_type, true);
        if (element.value == NO_WIR_VALUE) { return wir_no_expr(); }
        wir_move_or_retain(ref state, ref source, ref program, element);
        let index: WirValueID = wir_const_int(ref program, size_type, UInt128(UIntSize(i)));
        wir_store(ref program, state.block, element.value, wir_index_address(ref program, state.block, data, index, "", no_wir_location()), no_wir_location());
        i++;
    }
    wir_track_owned(ref state, vector, source_type);
    return WirExpr(value=vector, source_type=source_type);
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
    let state: WirFunctionLowering = WirFunctionLowering(function=function_id, return_type=TYPE_VOID, entry=entry, block=entry, bindings=[], loops=[], error_targets=[], owned_values=[], errors=[], terminated=false, next_block=0);

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
            if ((argument.name is !null && argument.name.length() != 0) || argument.is_spread) {
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

func wir_size_to_int(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirValueID) -> WirExpr {
    let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
    let limit: WirValueID = wir_const_int(ref program, size_type, UInt128(2147483648UL));
    wir_append(ref program, state.block, WirOpcode.BoundsCheck, program.void_type, [value, limit], [], no_wir_location());
    let result_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, TYPE_INT);
    if (size_type == result_type) { return WirExpr(value=value, source_type=TYPE_INT); }
    return WirExpr(value=wir_cast(ref program, state.block, value, result_type, "", no_wir_location()), source_type=TYPE_INT);
}

func wir_lower_length_call(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, call: CallNode, access: FieldAccessNode) -> WirMemberCall {
    if (access.field_name != "length") { return WirMemberCall(handled=false, value=wir_no_expr()); }
    let argument_count: Int = 0;
    if (call.args is !null) { argument_count = call.args.length(); }
    if (argument_count != 0) {
        state.errors.append("length() reached WIR lowering with arguments");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }

    let value: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, access.obj);
    if (value.value == NO_WIR_VALUE) { return WirMemberCall(handled=true, value=wir_no_expr()); }
    let source_type: Int = get_repr_type(ref source, value.source_type);
    if (source_type == TYPE_STRING) {
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [value.value], [], no_wir_location());
        let length_address: WirValueID = wir_field_address(ref program, state.block, value.value, 1, "", no_wir_location());
        return WirMemberCall(handled=true, value=WirExpr(value=wir_load(ref program, state.block, length_address, "", no_wir_location()), source_type=TYPE_INT));
    }

    let array: ArrayInfo = source.array_info_map.lookup("" + source_type);
    if (has_array_info(array)) {
        if (array.size >= 0) {
            let int_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, TYPE_INT);
            return WirMemberCall(handled=true, value=WirExpr(value=wir_const_int(ref program, int_type, UInt128(UInt32(array.size))), source_type=TYPE_INT));
        }
        let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
        let start: WirValueID = wir_field(ref program, state.block, value.value, 0, "", no_wir_location());
        let length: WirValueID = wir_field(ref program, state.block, value.value, 1, "", no_wir_location());
        let size_slot: WirValueID = wir_field(ref program, state.block, value.value, 4, "", no_wir_location());
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [size_slot], [], no_wir_location());
        let owner_size: WirValueID = wir_load(ref program, state.block, size_slot, "", no_wir_location());
        let end: WirValueID = wir_binary(ref program, state.block, WirOpcode.Add, size_type, start, length, "", no_wir_location());
        let one: WirValueID = wir_const_int(ref program, size_type, UInt128(1U));
        let upper_bound: WirValueID = wir_binary(ref program, state.block, WirOpcode.Add, size_type, owner_size, one, "", no_wir_location());
        wir_append(ref program, state.block, WirOpcode.BoundsCheck, program.void_type, [end, upper_bound], [], no_wir_location());
        return WirMemberCall(handled=true, value=wir_size_to_int(ref state, ref types, ref source, ref program, length));
    }

    let vector: SymbolInfo = source.vector_base_map.lookup("" + source_type);
    if (has_symbol(vector)) {
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [value.value], [], no_wir_location());
        let length: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, value.value, 0, "", no_wir_location()), "", no_wir_location());
        return WirMemberCall(handled=true, value=wir_size_to_int(ref state, ref types, ref source, ref program, length));
    }
    return WirMemberCall(handled=false, value=wir_no_expr());
}

func wir_lower_string_call(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, call: CallNode, access: FieldAccessNode) -> WirMemberCall {
    let object_type: Int = get_repr_type(ref source, wir_lvalue_type(state, source, access.obj));
    if (object_type != TYPE_STRING) { return WirMemberCall(handled=false, value=wir_no_expr()); }

    let target: FuncInfo = wir_compiler_link_function(ref source, "string_" + access.field_name);
    if (!has_func(target)) { return WirMemberCall(handled=false, value=wir_no_expr()); }
    let argument_count: Int = 0;
    if (call.args is !null) { argument_count = call.args.length(); }
    if (target.arg_types is null || argument_count + 1 != target.arg_types.length()) {
        state.errors.append("String method '" + access.field_name + "' reached WIR lowering with the wrong argument count");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }

    let function_id: WirFuncID = wir_find_function(program, target.name);
    if (function_id == NO_WIR_FUNC) { function_id = wir_lower_function_decl(ref types, ref source, ref program, target); }
    if (function_id == NO_WIR_FUNC) { return WirMemberCall(handled=true, value=wir_no_expr()); }

    let owned_start: Int = state.owned_values.length();
    let object: WirExpr = wir_lower_expected_expr(ref state, ref types, ref source, ref program, access.obj, TYPE_STRING);
    if (object.value == NO_WIR_VALUE) { return WirMemberCall(handled=true, value=wir_no_expr()); }
    object = wir_cast_expr(ref state, ref types, ref source, ref program, object, TYPE_STRING, true);
    if (object.value == NO_WIR_VALUE) { return WirMemberCall(handled=true, value=wir_no_expr()); }
    let arguments: Vector(WirValueID) = [object.value];

    let i: Int = 0;
    while (i < argument_count) {
        let argument: ArgNode = call.args[i];
        if ((argument.name is !null && argument.name.length() != 0) || argument.is_spread) {
            state.errors.append("Named and spread String method arguments must be bound before WIR lowering");
            return WirMemberCall(handled=true, value=wir_no_expr());
        }
        let parameter: TypeListNode = target.arg_types[i + 1];
        let value: WirExpr = wir_no_expr();
        if (parameter.pass_mode == PARAM_REF) {
            value = wir_lower_address(ref state, ref types, ref source, ref program, argument.val);
            if (value.value == NO_WIR_VALUE || value.source_type != parameter.type) {
                state.errors.append("Reference argument to String method '" + access.field_name + "' has the wrong type in WIR lowering");
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

    let result: WirValueID = wir_call(ref program, state.block, wir_function_value(program, function_id), arguments, "", no_wir_location());
    wir_cleanup_temporaries(ref state, ref source, ref program, owned_start);
    if (wir_value_needs_drop(ref source, target.ret_type)) { wir_track_owned(ref state, result, target.ret_type); }
    return WirMemberCall(handled=true, value=WirExpr(value=result, source_type=target.ret_type));
}

func wir_lower_vector_append(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, call: CallNode, access: FieldAccessNode) -> WirMemberCall {
    if (access.field_name != "append") { return WirMemberCall(handled=false, value=wir_no_expr()); }
    let source_type: Int = get_repr_type(ref source, wir_lvalue_type(state, source, access.obj));
    let vector: SymbolInfo = source.vector_base_map.lookup("" + source_type);
    if (!has_symbol(vector)) { return WirMemberCall(handled=false, value=wir_no_expr()); }
    let argument_count: Int = 0;
    if (call.args is !null) { argument_count = call.args.length(); }
    if (argument_count != 1) {
        state.errors.append("Vector append reached WIR lowering with the wrong argument count");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    let argument: ArgNode = call.args[0];
    if ((argument.name is !null && argument.name.length() != 0) || argument.is_spread) {
        state.errors.append("Named and spread Vector append arguments must be bound before WIR lowering");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    if (wir_lvalue_const(state, source, access.obj)) {
        state.errors.append("Vector append reached WIR lowering through a const value");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }

    let object: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, access.obj);
    if (object.value == NO_WIR_VALUE) { return WirMemberCall(handled=true, value=wir_no_expr()); }
    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [object.value], [], no_wir_location());
    let element: WirExpr = wir_lower_expected_expr(ref state, ref types, ref source, ref program, argument.val, vector.type);
    if (element.value == NO_WIR_VALUE) { return WirMemberCall(handled=true, value=wir_no_expr()); }
    element = wir_cast_expr(ref state, ref types, ref source, ref program, element, vector.type, true);
    if (element.value == NO_WIR_VALUE) { return WirMemberCall(handled=true, value=wir_no_expr()); }

    let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
    let element_wir: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, vector.type);
    let element_layout: WirTypeLayout = wir_type_layout(program, element_wir);
    if (!element_layout.valid || element_layout.size == 0UL) {
        state.errors.append("Vector element layout is unavailable during append lowering");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }

    let size_address: WirValueID = wir_field_address(ref program, state.block, object.value, 0, "", no_wir_location());
    let capacity_address: WirValueID = wir_field_address(ref program, state.block, object.value, 1, "", no_wir_location());
    let data_address: WirValueID = wir_field_address(ref program, state.block, object.value, 2, "", no_wir_location());
    let size: WirValueID = wir_load(ref program, state.block, size_address, "", no_wir_location());
    let capacity: WirValueID = wir_load(ref program, state.block, capacity_address, "", no_wir_location());
    let full: WirValueID = wir_binary(ref program, state.block, WirOpcode.UnsignedGreaterEqual, program.bool_type, size, capacity, "", no_wir_location());
    let grow: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "vector.grow."), []);
    let push: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "vector.push."), []);
    wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [full], [wir_edge(grow, []), wir_edge(push, [])], no_wir_location());

    let zero_capacity: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "vector.zero."), []);
    let double_capacity: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "vector.double."), []);
    let resize: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "vector.resize."), [wir_param("capacity", size_type)]);
    state.block = grow;
    let zero: WirValueID = wir_const_int(ref program, size_type, UInt128(0U));
    let is_zero: WirValueID = wir_binary(ref program, grow, WirOpcode.Equal, program.bool_type, capacity, zero, "", no_wir_location());
    wir_append(ref program, grow, WirOpcode.Branch, program.void_type, [is_zero], [wir_edge(zero_capacity, []), wir_edge(double_capacity, [])], no_wir_location());

    let initial_capacity: WirValueID = wir_const_int(ref program, size_type, UInt128(4U));
    wir_append(ref program, zero_capacity, WirOpcode.Jump, program.void_type, [], [wir_edge(resize, [initial_capacity])], no_wir_location());

    let max_bytes: UInt64 = 4294967295UL;
    if (program.pointer_bits == 64) { max_bytes = 18446744073709551615UL; }
    let max_capacity: UInt64 = max_bytes / element_layout.size;
    let growth_limit: WirValueID = wir_const_int(ref program, size_type, UInt128(max_capacity / 2UL));
    let overflow: WirValueID = wir_binary(ref program, double_capacity, WirOpcode.UnsignedGreater, program.bool_type, capacity, growth_limit, "", no_wir_location());
    let overflow_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "vector.overflow."), []);
    let calculate: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "vector.capacity."), []);
    wir_append(ref program, double_capacity, WirOpcode.Branch, program.void_type, [overflow], [wir_edge(overflow_block, []), wir_edge(calculate, [])], no_wir_location());
    wir_trap(ref program, overflow_block, no_wir_location());
    let two: WirValueID = wir_const_int(ref program, size_type, UInt128(2U));
    let doubled: WirValueID = wir_binary(ref program, calculate, WirOpcode.Multiply, size_type, capacity, two, "", no_wir_location());
    wir_append(ref program, calculate, WirOpcode.Jump, program.void_type, [], [wir_edge(resize, [doubled])], no_wir_location());

    state.block = resize;
    let resize_block: WirBlock = program.arena.blocks[wir_id_index(UInt32(resize))];
    let new_capacity: WirValueID = resize_block.parameters[0];
    let element_size: WirValueID = wir_const_int(ref program, size_type, UInt128(element_layout.size));
    let bytes: WirValueID = wir_binary(ref program, resize, WirOpcode.Multiply, size_type, new_capacity, element_size, "", no_wir_location());
    let resizer: FuncInfo = wir_compiler_link_function(ref source, "memory_resize");
    if (!has_func(resizer)) {
        state.errors.append("Vector append requires the memory_resize compiler link");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    let resizer_id: WirFuncID = wir_find_function(program, resizer.name);
    if (resizer_id == NO_WIR_FUNC) { resizer_id = wir_lower_function_decl(ref types, ref source, ref program, resizer); }
    if (resizer_id == NO_WIR_FUNC) { return WirMemberCall(handled=true, value=wir_no_expr()); }
    let old_data: WirValueID = wir_load(ref program, resize, data_address, "", no_wir_location());
    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let raw_data: WirValueID = wir_cast(ref program, resize, old_data, raw_pointer, "", no_wir_location());
    let new_raw_data: WirValueID = wir_call(ref program, resize, wir_function_value(program, resizer_id), [raw_data, bytes], "", no_wir_location());
    wir_append(ref program, resize, WirOpcode.NullCheck, program.void_type, [new_raw_data], [], no_wir_location());
    let data_type: WirTypeID = wir_value_type(program, old_data);
    let new_data: WirValueID = wir_cast(ref program, resize, new_raw_data, data_type, "", no_wir_location());
    wir_store(ref program, resize, new_data, data_address, no_wir_location());
    wir_store(ref program, resize, new_capacity, capacity_address, no_wir_location());
    wir_append(ref program, resize, WirOpcode.Jump, program.void_type, [], [wir_edge(push, [])], no_wir_location());

    state.block = push;
    let final_data: WirValueID = wir_load(ref program, push, data_address, "", no_wir_location());
    let slot: WirValueID = wir_index_address(ref program, push, final_data, size, "", no_wir_location());
    wir_move_or_retain(ref state, ref source, ref program, element);
    wir_store(ref program, push, element.value, slot, no_wir_location());
    let one: WirValueID = wir_const_int(ref program, size_type, UInt128(1U));
    let new_size: WirValueID = wir_binary(ref program, push, WirOpcode.Add, size_type, size, one, "", no_wir_location());
    wir_store(ref program, push, new_size, size_address, no_wir_location());
    return WirMemberCall(handled=true, value=WirExpr(value=NO_WIR_VALUE, source_type=TYPE_VOID));
}

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
    let argument_count: Int = 0;
    if (call.args is !null) { argument_count = call.args.length(); }
    let parameter_count: Int = 0;
    if (method_node.params is !null) { parameter_count = method_node.params.length(); }
    if (argument_count != parameter_count) {
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
    while (i < argument_count) {
        let argument: ArgNode = call.args[i];
        if ((argument.name is !null && argument.name.length() != 0) || argument.is_spread) {
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
    let argument_count: Int = 0;
    if (call.args is !null) { argument_count = call.args.length(); }
    if (argument_count + 1 != signature.parameters.length()) {
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
    while (i < argument_count) {
        let argument: ArgNode = call.args[i];
        if ((argument.name is !null && argument.name.length() != 0) || argument.is_spread) {
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
    let value: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, node);
    if (value.value == NO_WIR_VALUE || expected_type == TYPE_AUTO || expected_type == TYPE_POISON) { return value; }
    if (node_tag(node) == NODE_INT && is_integer_type(value.source_type) && is_integer_type(expected_type)) {
        return wir_cast_expr(ref state, ref types, ref source, ref program, value, expected_type, false);
    }
    return value;
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
    let can_resolve_intrinsic: Bool = source.global_symbol_table is !null && source.current_file_global_aliases is !null && source.global_var_aliases is !null && source.symbol_table.table is !null;
    if (can_resolve_intrinsic && (kind == NODE_VAR_ACCESS || kind == NODE_FIELD_ACCESS)) {
        let intrinsic_info: SymbolInfo = target_intrinsic_symbol(ref source, node);
        if (has_symbol(intrinsic_info)) {
            let intrinsic: String = intrinsic_info.reg.slice(11, intrinsic_info.reg.length());
            let source_type: Int = intrinsic_info.type;
            let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
            if (type_id == NO_WIR_TYPE) { return wir_no_expr(); }
            return WirExpr(value=wir_const_int(ref program, type_id, UInt128(target_value(intrinsic))), source_type=source_type);
        }
    }
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
    if (kind == NODE_CHAR) {
        let literal: CharNode = get_char_node(source.arena, node);
        let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, TYPE_CHAR);
        return WirExpr(value=wir_const_int(ref program, type_id, UInt128(string_to_int(literal.tok.value, literal.pos))), source_type=TYPE_CHAR);
    }
    if (kind == NODE_BOOL) {
        let literal: BooleanNode = get_bool_node(source.arena, node);
        return WirExpr(value=wir_const_bool(ref program, literal.value != 0), source_type=TYPE_BOOL);
    }
    if (kind == NODE_STRING) {
        let literal: StringNode = get_string_node(source.arena, node);
        return WirExpr(value=wir_lower_string_constant(ref types, ref program, literal.tok.value), source_type=TYPE_STRING);
    }
    if (kind == NODE_NULL || kind == NODE_NULLPTR) {
        let type_id: WirTypeID = wir_opaque_pointer(ref types, ref program);
        let source_type: Int = TYPE_NULL;
        if (kind == NODE_NULLPTR) { source_type = TYPE_NULLPTR; }
        return WirExpr(value=wir_null(ref program, type_id), source_type=source_type);
    }
    if (kind == NODE_TYPE_LAYOUT) {
        let query: TypeLayoutNode = get_type_layout_node(source.arena, node);
        let source_type: Int = resolve_type(ref source, query.type_node);
        let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
        if (type_id == NO_WIR_TYPE) { return wir_no_expr(); }
        let layout: WirTypeLayout = wir_type_layout(program, type_id);
        if (!layout.valid) {
            state.errors.append("type layout is unavailable during WIR lowering");
            return wir_no_expr();
        }
        let value: UInt128 = UInt128(layout.size);
        if (query.is_align) { value = UInt128(layout.alignment); }
        let result_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, TYPE_UINTSIZE);
        return WirExpr(value=wir_const_int(ref program, result_type, value), source_type=TYPE_UINTSIZE);
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
        let access: FieldAccessNode = get_field_access_node(source.arena, node);
        let enum_member: WirEnumValue = wir_enum_member(ref types, ref source, access);
        if (enum_member.source_type != 0) {
            let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, enum_member.source_type);
            if (type_id == NO_WIR_TYPE) { return wir_no_expr(); }
            return WirExpr(value=wir_const_int(ref program, type_id, UInt128(enum_member.value)), source_type=enum_member.source_type);
        }
        let global: WirSourceGlobal = wir_direct_global(ref state, ref source, node);
        if (has_wir_source_global(global)) {
            let global_id: WirGlobalID = wir_find_global(program, global.name);
            if (global_id == NO_WIR_GLOBAL) {
                state.errors.append("global '" + global.name + "' was not declared before WIR lowering");
                return wir_no_expr();
            }
            return WirExpr(value=wir_load(ref program, state.block, wir_global_value(program, global_id), "", no_wir_location()), source_type=global.source_type);
        }
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
    if (kind == NODE_IS || kind == NODE_IS_NOT) {
        let identity: BinOpNode = get_binop_node(source.arena, node);
        let left: WirExpr = wir_identity_operand(ref state, ref types, ref source, ref program, identity.left);
        let right: WirExpr = wir_identity_operand(ref state, ref types, ref source, ref program, identity.right);
        if (left.value == NO_WIR_VALUE || right.value == NO_WIR_VALUE) { return wir_no_expr(); }
        let opcode: WirOpcode = WirOpcode.Equal;
        if (kind == NODE_IS_NOT) { opcode = WirOpcode.NotEqual; }
        return WirExpr(value=wir_binary(ref program, state.block, opcode, program.bool_type, left.value, right.value, "", no_wir_location()), source_type=TYPE_BOOL);
    }
    if (kind == NODE_INDEX_ACCESS) {
        return wir_lower_index_expr(ref state, ref types, ref source, ref program, get_index_access_node(source.arena, node));
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
        if (!has_node(postfix.node)) {
            state.errors.append("postfix operator has no target in WIR lowering");
            return wir_no_expr();
        }
        if (wir_lvalue_const(state, source, postfix.node)) {
            state.errors.append("const value reached WIR postfix lowering");
            return wir_no_expr();
        }
        let address: WirExpr = wir_lower_lvalue(ref state, ref types, ref source, ref program, postfix.node);
        if (address.value == NO_WIR_VALUE) { return wir_no_expr(); }
        if (!wir_source_numeric(address.source_type)) {
            state.errors.append("postfix operator reached WIR lowering with a non-numeric operand");
            return wir_no_expr();
        }

        let old_value: WirValueID = wir_load(ref program, state.block, address.value, "", no_wir_location());
        let one: WirValueID = wir_one(ref types, ref source, ref program, address.source_type);
        let opcode: WirOpcode = WirOpcode.Add;

        if (postfix.op_tok.type == TOK_DEC) {
            opcode = WirOpcode.Subtract;
        }

        let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, address.source_type);
        let new_value: WirValueID = wir_binary(ref program, state.block, opcode, type_id, old_value, one, "", no_wir_location());
        wir_store(ref program, state.block, new_value, address.value, no_wir_location());
        return WirExpr(value=old_value, source_type=address.source_type);
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
            wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(merge_block, [right.value])], no_wir_location());
            state.block = merge_block;
            let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(merge_block))];
            return WirExpr(value=block.parameters[0], source_type=TYPE_BOOL);
        }

        let owned_start: Int = state.owned_values.length();
        let left: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, binary.left);
        let right: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, binary.right);
        if (left.value == NO_WIR_VALUE || right.value == NO_WIR_VALUE) { return wir_no_expr(); }
        if (binary.op_tok.type == TOK_PLUS && get_repr_type(ref source, left.source_type) == TYPE_STRING && get_repr_type(ref source, right.source_type) == TYPE_STRING) {
            let target: FuncInfo = wir_compiler_link_function(ref source, "string_concat");
            if (!has_func(target)) {
                state.errors.append("String concatenation runtime function is unavailable during WIR lowering");
                return wir_no_expr();
            }
            let function_id: WirFuncID = wir_find_function(program, target.name);
            if (function_id == NO_WIR_FUNC) { function_id = wir_lower_function_decl(ref types, ref source, ref program, target); }
            if (function_id == NO_WIR_FUNC) { return wir_no_expr(); }
            let result: WirValueID = wir_call(ref program, state.block, wir_function_value(program, function_id), [left.value, right.value], "", no_wir_location());
            wir_cleanup_temporaries(ref state, ref source, ref program, owned_start);
            wir_track_owned(ref state, result, TYPE_STRING);
            return WirExpr(value=result, source_type=TYPE_STRING);
        }
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
    if (kind == NODE_TRY_UNWRAP) {
        return wir_lower_try_unwrap(ref state, ref types, ref source, ref program, get_try_unwrap_node(source.arena, node));
    }
    if (kind == NODE_CALL) {
        let call: CallNode = get_call_node(source.arena, node);
        let cast_target: Int = wir_cast_target(ref source, call.callee);
        if (cast_target != 0) {
            let argument_count: Int = 0;
            if (call.args is !null) { argument_count = call.args.length(); }
            if (argument_count != 1) {
                state.errors.append("type conversion reached WIR lowering with the wrong argument count");
                return wir_no_expr();
            }
            let argument: ArgNode = call.args[0];
            if ((argument.name is !null && argument.name.length() != 0) || argument.is_spread) {
                state.errors.append("named or spread argument reached WIR type conversion");
                return wir_no_expr();
            }
            let value: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, argument.val);
            if (value.value == NO_WIR_VALUE) { return wir_no_expr(); }
            let source_info: StructInfo = StructInfo();
            if (source.struct_id_map is !null) { source_info = source.struct_id_map.lookup("" + get_repr_type(ref source, value.source_type)); }
            if (has_struct(source_info) && source_info.is_class && has_func(find_class_conversion(source_info, cast_target))) {
                state.errors.append("class-defined conversion is not lowered to WIR yet");
                return wir_no_expr();
            }
            let literal: Bool = node_tag(argument.val) == NODE_INT || node_tag(argument.val) == NODE_FLOAT || node_tag(argument.val) == NODE_CHAR;
            if (wir_cast_needs_check(ref source, value.source_type, cast_target) && !literal) {
                let valid: WirValueID = wir_cast_condition(ref state, ref source, ref program, value, cast_target);
                if (valid == NO_WIR_VALUE) {
                    state.errors.append("checked type conversion has no validity condition");
                    return wir_no_expr();
                }
                if (call.preserve_fallible) {
                    return wir_lower_fallible_cast(ref state, ref types, ref source, ref program, value, cast_target, valid);
                }
                wir_guard_cast(ref state, ref program, valid);
            }
            return wir_cast_expr(ref state, ref types, ref source, ref program, value, cast_target, false);
        }
        let source_argument_values: Vector(NodeID) = [];
        let source_argument_named: Vector(Bool) = [];
        let source_argument_spreads: Vector(Bool) = [];
        let source_argument_index: Int = 0;
        while (call.args is !null && source_argument_index < call.args.length()) {
            let source_argument: ArgNode = call.args[source_argument_index];
            source_argument_values.append(source_argument.val);
            source_argument_named.append(source_argument.name is !null && source_argument.name.length() != 0);
            source_argument_spreads.append(source_argument.is_spread);
            source_argument_index++;
        }
        let info: FuncInfo = wir_direct_function(ref state, ref source, call.callee);
        let source_parameter_types: Vector(Int) = [];
        let source_parameter_modes: Vector(Int) = [];
        if (has_func(info)) {
            let parameter_index: Int = 0;
            while (info.arg_types is !null && parameter_index < info.arg_types.length()) {
                let parameter: TypeListNode = info.arg_types[parameter_index];
                source_parameter_types.append(parameter.type);
                source_parameter_modes.append(parameter.pass_mode);
                parameter_index++;
            }
        }
        if (!has_func(info)) {
            if (node_tag(call.callee) == NODE_FIELD_ACCESS) {
                let access: FieldAccessNode = get_field_access_node(source.arena, call.callee);
                let length_call: WirMemberCall = wir_lower_length_call(ref state, ref types, ref source, ref program, call, access);
                if (length_call.handled) { return length_call.value; }
                let string_call: WirMemberCall = wir_lower_string_call(ref state, ref types, ref source, ref program, call, access);
                if (string_call.handled) { return string_call.value; }
                let vector_append: WirMemberCall = wir_lower_vector_append(ref state, ref types, ref source, ref program, call, access);
                if (vector_append.handled) { return vector_append.value; }
            }
            let member_call: WirMemberCall = wir_lower_class_call(ref state, ref types, ref source, ref program, call);
            if (member_call.handled) { return member_call.value; }
        }
        let constructor: StructInfo = wir_struct_constructor(ref source, call.callee);
        if (has_struct(constructor) && !constructor.is_interface && !constructor.is_enum) {
            if (constructor.is_class) { return wir_lower_class_constructor(ref state, ref types, ref source, ref program, call, constructor); }
            return wir_lower_struct_constructor(ref state, ref types, ref source, ref program, call, constructor);
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
            source_parameter_types = [];
            source_parameter_modes = [];
            let source_index: Int = 0;
            while (signature_info.func_arg_types is !null && source_index < signature_info.func_arg_types.length()) {
                let parameter: TypeListNode = signature_info.func_arg_types[source_index];
                source_parameter_types.append(parameter.type);
                source_parameter_modes.append(parameter.pass_mode);
                source_index++;
            }
            result_type = signature_info.type;
        }

        let signature_type: WirTypeID = wir_value_type(program, callee_value);
        let parameter_count: Int = program.arena.types[wir_id_index(UInt32(signature_type))].parameters.length();
        let owned_start: Int = state.owned_values.length();
        let arguments: Vector(WirValueID) = [];
        let i: Int = 0;
        while (i < source_argument_values.length()) {
            let source_argument_has_name: Bool = source_argument_named[i];
            let source_argument_spread: Bool = source_argument_spreads[i];
            if (source_argument_has_name || source_argument_spread) {
                state.errors.append("named and spread arguments must be bound before WIR lowering");
                return wir_no_expr();
            }
            let value: WirExpr = wir_no_expr();
            if (i < parameter_count) {
                let parameter_type: Int = source_parameter_types[i];
                if (source_parameter_modes[i] == PARAM_REF) {
                    value = wir_lower_address(ref state, ref types, ref source, ref program, source_argument_values[i]);
                    if (value.value == NO_WIR_VALUE) { return wir_no_expr(); }
                    if (value.source_type != parameter_type) {
                        state.errors.append("Reference argument to '" + callable_name + "' has the wrong type in WIR lowering");
                        return wir_no_expr();
                    }
                } else {
                    value = wir_lower_expected_expr(ref state, ref types, ref source, ref program, source_argument_values[i], parameter_type);
                    if (value.value == NO_WIR_VALUE) { return wir_no_expr(); }
                    value = wir_cast_expr(ref state, ref types, ref source, ref program, value, parameter_type, true);
                    if (value.value == NO_WIR_VALUE) { return wir_no_expr(); }
                }
            } else {
                value = wir_lower_expr(ref state, ref types, ref source, ref program, source_argument_values[i]);
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

func wir_loop_has_break(ref source: Compiler, node: NodeID) -> Bool {
    if (!has_node(node)) { return false; }
    let kind: Int = node_tag(node);
    if (kind == NODE_BREAK) { return true; }
    if (kind == NODE_WHILE || kind == NODE_FOR) { return false; }
    if (kind == NODE_BLOCK) {
        let block: BlockNode = get_block_node(source.arena, node);
        let i: Int = 0;
        while (block.stmts is !null && i < block.stmts.length()) {
            if (wir_loop_has_break(ref source, block.stmts[i])) { return true; }
            i++;
        }
        return false;
    }
    if (kind == NODE_IF) {
        let branch: IfNode = get_if_node(source.arena, node);
        return wir_loop_has_break(ref source, branch.body) || wir_loop_has_break(ref source, branch.else_body);
    }
    if (kind == NODE_CATCH) {
        let caught: CatchNode = get_catch_node(source.arena, node);
        return wir_loop_has_break(ref source, caught.stmt) || wir_loop_has_break(ref source, caught.body);
    }
    return false;
}

func wir_lower_stmt(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: NodeID) -> Void {
    if (state.terminated || !has_node(node)) { return; }
    let kind: Int = node_tag(node);
    if (kind == NODE_CATCH) {
        wir_lower_catch(ref state, ref types, ref source, ref program, get_catch_node(source.arena, node));
        return;
    }
    if (kind == NODE_TRY_UNWRAP) {
        wir_lower_expr(ref state, ref types, ref source, ref program, node);
        return;
    }
    if (kind == NODE_THROW) {
        wir_lower_throw(ref state, ref types, ref source, ref program, get_throw_node(source.arena, node));
        return;
    }
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
        if (is_fallible_type(ref source, state.return_type)) {
            let inner_type: Int = get_inner_fallible_type(ref source, state.return_type);
            let value: WirExpr = wir_no_expr();
            if (has_node(statement.value)) { value = wir_lower_expr(ref state, ref types, ref source, ref program, statement.value); }
            if (value.value != NO_WIR_VALUE && value.source_type == state.return_type) {
                result = value;
                wir_move_or_retain(ref state, ref source, ref program, result);
            } else if (inner_type == TYPE_VOID) {
                if (value.value != NO_WIR_VALUE) {
                    state.errors.append("fallible Void function reached WIR lowering with a return value");
                    return;
                }
                result = WirExpr(value=wir_success_result(ref state, ref types, ref source, ref program, value), source_type=state.return_type);
            } else {
                if (value.value == NO_WIR_VALUE) {
                    state.errors.append("fallible function reached WIR lowering without a success value");
                    return;
                }
                value = wir_cast_expr(ref state, ref types, ref source, ref program, value, inner_type, true);
                if (value.value == NO_WIR_VALUE) { return; }
                wir_move_or_retain(ref state, ref source, ref program, value);
                result = WirExpr(value=wir_success_result(ref state, ref types, ref source, ref program, value), source_type=state.return_type);
            }
            if (result.value == NO_WIR_VALUE || wir_value_type(program, result.value) != signature.result) {
                state.errors.append("fallible return value has the wrong WIR type");
                return;
            }
        } else if (has_node(statement.value)) {
            result = wir_lower_expected_expr(ref state, ref types, ref source, ref program, statement.value, state.return_type);
        }
        if (signature.result == program.void_type) {
            if (result.value != NO_WIR_VALUE) { state.errors.append("Void function reached WIR lowering with a return value"); return; }
        } else if (result.value == NO_WIR_VALUE) {
            state.errors.append("non-Void function reached WIR lowering without a return value");
            return;
        } else if (!is_fallible_type(ref source, state.return_type)) {
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
        let constant_true: Bool = node_tag(statement.condition) == NODE_BOOL && get_bool_node(source.arena, statement.condition).value == 1;
        let constant_false: Bool = node_tag(statement.condition) == NODE_BOOL && get_bool_node(source.arena, statement.condition).value == 0;
        if (constant_true) {
            wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(body_block, [])], no_wir_location());
        } else if (constant_false) {
            wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(end_block, [])], no_wir_location());
        } else {
            wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [condition.value], [wir_edge(body_block, []), wir_edge(end_block, [])], no_wir_location());
        }

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
        if (constant_true && !wir_loop_has_break(ref source, statement.body)) {
            wir_append(ref program, end_block, WirOpcode.Unreachable, program.void_type, [], [], no_wir_location());
            state.terminated = true;
        } else {
            state.terminated = false;
        }
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
    let state: WirFunctionLowering = WirFunctionLowering(function=function_id, return_type=info.ret_type, entry=entry, block=entry, bindings=[], loops=[], error_targets=[], owned_values=[], errors=[], terminated=false, next_block=0);
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
        types.errors.append("In function '" + info.name + "': " + state.errors[i]);
        i++;
    }
    return function_id;
}
