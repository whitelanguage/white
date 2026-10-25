// src/compiler/wir/lowering/functions.wl
import * from "../model.wl"
import * from "../builder.wl"
import * from "../layout.wl"
import * from "../runtime.wl"
import * from "state.wl"
import * from "types.wl"
import * from "ownership.wl"
import * from "unions.wl"
import * from "../../narrowing.wl"
import * from "static_data.wl"
import * from "declarations.wl"
import * from "globals.wl"
import * from "dictionary_runtime.wl"
import * from "closure_environment.wl"
import * from "../../context.wl"
import find_interface_implementation from "../../analysis.wl"
import has_index_refs, check_body_refs from "../../references.wl"
import parse_const_uint128, parse_decimal_float_literal, eval_const_long, check_layout_type from "../../constants.wl"
import class_has_interface, is_unsuffix_int_literal, bind_call_args, bind_native_args, bind_callable_args, callable_types_compatible, is_ref_binding_init, expr_root_name from "../../validation.wl"
import check_null_return from "../../validation.wl"
import check_struct_init, struct_arg_supplied from "../../initialization.wl"
import is_typed_dict, is_dict_key_type from "../../lowering/dictionary.wl"
import validate_explicit_literal_cast from "../../lowering/casts.wl"
import target_intrinsic_symbol, target_value, fold_target_cond from "../../target_eval.wl"
import * from "../../../frontend/ast.wl"
import * from "../../../frontend/arena.wl"
import * from "../../../frontend/tokens.wl"
import Position, no_position, throw_name_error, throw_type_error, throw_invalid_syntax, throw_overflow_error, GLOBAL_ERROR_COUNT from "../../../frontend/diagnostics.wl"


struct WirMemberCall(
    handled: Bool,
    value: WirExpr
)

struct WirVariadicSource(
    value: WirExpr,
    spread: Bool,
    length: WirValueID,
    data: WirValueID
)

struct WirCallArguments(
    valid: Bool,
    values: Vector(WirValueID)
)

struct WirPrintSource(
    value: WirExpr,
    spread: Bool,
    length: WirValueID,
    data: WirValueID,
    element_type: Int
)

func wir_check_fallible_call(ref source: Compiler, call: CallNode, return_type: Int, name: String) -> Bool {
    if (!is_fallible_type(ref source, return_type) || call.preserve_fallible) {
        return true;
    }

    let message: String = "fallible call requires '?'";
    if (name is !null && name.length() > 0) {
        message = "call to fallible function '" + name + "' requires '?'";
    }
    throw_type_error(call.pos, message);
    return false;
}

func wir_find_binding(ref state: WirFunctionLowering, name: String) -> WirBinding? {
    let index = wir_local_index(ref state, name);
    if (index >= 0) { return state.bindings[index]; }
    throw Error.InvalidData;
}

func wir_name_is_value(ref state: WirFunctionLowering, ref source: Compiler, name: String) -> Bool {
    let binding: WirBinding = wir_find_binding(ref state, name)?;
    catch(err) {
        return has_wir_source_global(wir_source_global(ref source, name));
    }
    return true;
}

func wir_has_local_binding(ref state: WirFunctionLowering, name: String) -> Bool {
    let binding: WirBinding = wir_find_binding(ref state, name)?;
    catch(err) { return false; }
    return true;
}

func wir_module_symbol(ref state: WirFunctionLowering, ref source: Compiler, node: NodeID) -> String {
    if (!has_node(node) || node_tag(node) != NODE_FIELD_ACCESS) {
        return "";
    }

    let path: String = format_ast_path(ref source, node);
    let dot: Int = 0;
    while (dot < path.length() && path[dot] != '.') { dot++; }
    if (dot <= 0 || dot >= path.length()) { return ""; }

    let root: String = path.slice(0, dot);
    if (wir_has_local_binding(ref state, root)) {
        return "";
    }
    let prefix: Optional(String) = source.current_file_visible_prefixes.lookup(root);
    if (prefix is null) { return ""; }

    return prefix + path.slice(dot + 1, path.length());
}

func wir_path_root(ref source: Compiler, node: NodeID) -> String {
    while (has_node(node) && node_tag(node) == NODE_FIELD_ACCESS) {
        node = get_field_access_node(ref source.arena, node).obj;
    }
    if (has_node(node) && node_tag(node) == NODE_VAR_ACCESS) {
        return get_var_access_node(ref source.arena, node).name_tok.value;
    }
    return "";
}

func wir_unknown_path_root(ref state: WirFunctionLowering, ref source: Compiler, node: NodeID) -> String {
    let root: String = wir_path_root(ref source, node);
    if (root.length() == 0 || wir_has_local_binding(ref state, root)) { return ""; }
    if (source.current_file_visible_prefixes.lookup(root) is !null) { return ""; }
    if (source.current_file_type_aliases.lookup(root) is !null) { return ""; }
    if ((source.struct_table.lookup(root) is !null)) { return ""; }
    if ((source.struct_table.lookup(source.current_package_prefix + root) is !null)) { return ""; }
    if (has_wir_source_global(wir_source_global(ref source, root)) || (wir_source_function(ref source, root) is !null)) { return ""; }
    return root;
}

func wir_unknown_call_root(ref state: WirFunctionLowering, ref source: Compiler, node: NodeID) -> String {
// type names are handled as constructors before this check, a remaining dotted call needs a value or namespace
    let root: String = wir_path_root(ref source, node);
    if (root.length() == 0 || wir_has_local_binding(ref state, root)) { return ""; }
    if (source.current_file_visible_prefixes.lookup(root) is !null) { return ""; }
    if (has_wir_source_global(wir_source_global(ref source, root)) || (wir_source_function(ref source, root) is !null)) { return ""; }
    return root;
}

func wir_source_function(ref source: Compiler, name: String) -> Optional(FuncInfo) {
    let info: Optional(FuncInfo) = null;
    if (source.current_package_prefix.length() != 0) {
        info = source.func_table.lookup(source.current_package_prefix + name);
    }
    if (info is null) { info = source.func_table.lookup(name); }
    if (!(info is !null)) {
        let mapped: Optional(String) = source.current_file_func_aliases.lookup(name);
        if (mapped is !null) { info = source.func_table.lookup(mapped); }
    }
    if (!(info is !null)) {
        let mapped: Optional(String) = source.global_func_aliases.lookup(name);
        if (mapped is !null) { info = source.func_table.lookup(mapped); }
    }
    return info;
}

func wir_direct_function(ref state: WirFunctionLowering, ref source: Compiler, callee: NodeID) -> Optional(FuncInfo) {
    if (!has_node(callee)) {
        return null;
    }
    let kind: Int = node_tag(callee);
    if (kind == NODE_VAR_ACCESS) {
        let name: String = get_var_access_node(ref source.arena, callee).name_tok.value;
        if (!wir_name_is_value(ref state, ref source, name)) {
            return wir_source_function(ref source, name);
        }
        return null;
    }
    if (kind != NODE_FIELD_ACCESS) {
        return null;
    }

    let access: FieldAccessNode = get_field_access_node(ref source.arena, callee);
    let path: Vector(String) = [];
    let root_node: NodeID = access.obj;
    while (has_node(root_node) && node_tag(root_node) == NODE_FIELD_ACCESS) {
        let part: FieldAccessNode = get_field_access_node(ref source.arena, root_node);
        path.append(part.field_name);
        root_node = part.obj;
    }
    if (has_node(root_node) && node_tag(root_node) == NODE_VAR_ACCESS) {
        let root: String = get_var_access_node(ref source.arena, root_node).name_tok.value;
        if (wir_has_local_binding(ref state, root)) {
            return null;
        }
        let name: String = "";
        let prefix: Optional(String) = source.current_file_visible_prefixes.lookup(root);
        if (prefix is !null && !access.field_name.starts_with("__")) {
            name = module_member_name(prefix, path, access.field_name);
        }
        if (name.length() == 0) {
            let source_name: String = module_member_name(root + ".", path, access.field_name);
            let mapped: Optional(String) = source.current_file_func_aliases.lookup(source_name);
            if (mapped is !null) { name = mapped; }
        }
        if (name.length() != 0) {
            let info: Optional(FuncInfo) = wir_source_function(ref source, name);
            if ((info is !null)) { return info; }
        }
    }
    return null;
}

func wir_generic_call_function(ref state: WirFunctionLowering, ref source: Compiler, call: CallNode) -> Optional(FuncInfo) {
    let callee: NodeID = call.callee;
    if (has_node(callee) && node_tag(callee) == NODE_GENERIC_TYPE) {
        callee = get_generic_type_node(ref source.arena, callee).base_type;
    }
    if (!has_node(callee)) {
        return null;
    }

    let name: String = generic_symbol_name(ref source, callee, true);
    let generic: Optional(GenericTemplate) = source.generic_funcs.lookup(name);
    if (!(generic is !null)) {
        return null;
    }
    let meta_generic: GenericTemplate = generic;

    let arguments: Vector(Struct) = [];
    if (call.type_args.length() != 0) {
        let resolved = resolve_generic_args(ref source, meta_generic, call.type_args, [], call.pos);
        if (resolved is null) { return null; }
        arguments = resolved;
    } else {
        let definition: FunctionDefNode = get_func_def_node(ref source.arena, meta_generic.node);
        let inferred: Dict(String, SymbolInfo) = Dict();
        let i: Int = 0;
        while (call.args is !null && definition.params is !null && i < call.args.length()) {
            let argument: ArgNode = call.args[i];
            let parameter_index: Int = generic_call_param(definition.params, argument, i);
            if (parameter_index >= 0) {
                let actual_type: Int = wir_generic_argument_type(ref state, ref source, argument, definition.params[parameter_index]);
                if (actual_type == TYPE_POISON || !infer_type_args(ref source, meta_generic, definition.params[parameter_index].type_tok, actual_type, inferred, call.pos)) {
                    return null;
                }
            }
            i++;
        }
        i = 0;
        while (i < meta_generic.type_params.length()) {
            let parameter: GenericParamNode = meta_generic.type_params[i];
            let actual: Optional(SymbolInfo) = inferred.lookup(parameter.name_tok.value);
            if (!(actual is !null)) {
                return null;
            }
            arguments.append(TypeListNode(type=actual.type, pass_mode=0));
            i++;
        }
    }
    if (arguments is null) {
        return null;
    }
    return register_generic_func(ref source, meta_generic, arguments, call.pos);
}

func wir_generic_constructor_type(ref state: WirFunctionLowering, ref source: Compiler, call: CallNode) -> Int {
    let generic: Optional(GenericTemplate) = wir_generic_constructor(ref source, call.callee);
    if (!(generic is !null)) { return 0; }
    let meta_generic: GenericTemplate = generic;
    if (!use_generic_constructor(ref source, meta_generic.name, meta_generic, call.type_args, call.args, 0)) { return 0; }

    let arguments: Vector(Struct) = [];
    if (call.type_args.length() != 0) {
        let resolved = resolve_generic_constructor_args(ref source, meta_generic, call.type_args, call.args, 0, call.pos);
        if (resolved is null) { return TYPE_POISON; }
        arguments = resolved;
    } else {
        let inferred: Dict(String, SymbolInfo) = Dict();
        let parameters: Vector(ParamNode) = generic_constructor_params(ref source, meta_generic);
        let i: Int = 0;
        while (call.args is !null && parameters is !null && i < call.args.length()) {
            let argument: ArgNode = call.args[i];
            let parameter_index: Int = generic_call_param(parameters, argument, i);
            if (parameter_index >= 0) {
                let actual_type: Int = wir_generic_argument_type(ref state, ref source, argument, parameters[parameter_index]);
                if (actual_type == TYPE_POISON || !infer_type_args(ref source, meta_generic, parameters[parameter_index].type_tok, actual_type, inferred, call.pos)) {
                    return TYPE_POISON;
                }
            }
            i++;
        }

        i = 0;
        while (i < meta_generic.type_params.length()) {
            let parameter: GenericParamNode = meta_generic.type_params[i];
            let actual: Optional(SymbolInfo) = inferred.lookup(parameter.name_tok.value);
            if (!(actual is !null)) {
                throw_type_error(call.pos, "Cannot infer type argument '" + parameter.name_tok.value + "' for type '" + meta_generic.name + "'.");
                return TYPE_POISON;
            }
            arguments.append(TypeListNode(type=actual.type, pass_mode=0));
            i++;
        }
    }
    if (arguments is null) { return TYPE_POISON; }

    let template_kind: Int = node_tag(meta_generic.node);
    if (template_kind == NODE_CLASS_DEF) {
        return register_generic_class(ref source, meta_generic, arguments, call.pos);
    }
    return register_generic_struct(ref source, meta_generic, arguments, call.pos);
}

func wir_argument_type(ref state: WirFunctionLowering, ref source: Compiler, node: NodeID) -> Int {
    if (!has_node(node)) { return TYPE_POISON; }
    if (node_tag(node) == NODE_TRY_UNWRAP) {
        let wrapped: Int = wir_argument_type(ref state, ref source, get_try_unwrap_node(ref source.arena, node).expr);
        if (is_fallible_type(ref source, wrapped)) {
            return get_inner_fallible_type(ref source, wrapped);
        }
        return wrapped;
    }
    if (node_tag(node) == NODE_UNARYOP) {
        let unary: UnaryOpNode = get_unary_node(ref source.arena, node);
        if (unary.op_tok.type == TOK_NOT) { return TYPE_BOOL; }
        return wir_argument_type(ref state, ref source, unary.node);
    }
    if (node_tag(node) == NODE_BINOP) {
        let binary: BinOpNode = get_binop_node(ref source.arena, node);
        let left_type: Int = wir_argument_type(ref state, ref source, binary.left);
        let right_type: Int = wir_argument_type(ref state, ref source, binary.right);
        if (left_type == TYPE_POISON || right_type == TYPE_POISON) { return TYPE_POISON; }
        if (binary.op_tok.type == TOK_AND || binary.op_tok.type == TOK_OR ||
            binary.op_tok.type == TOK_EE || binary.op_tok.type == TOK_NE ||
            binary.op_tok.type == TOK_LT || binary.op_tok.type == TOK_LTE ||
            binary.op_tok.type == TOK_GT || binary.op_tok.type == TOK_GTE ||
            binary.op_tok.type == TOK_IS) {
            return TYPE_BOOL;
        }
        if (binary.op_tok.type == TOK_POW) { return TYPE_FLOAT; }
        if (get_repr_type(ref source, left_type) == TYPE_STRING || get_repr_type(ref source, right_type) == TYPE_STRING) {
            if (binary.op_tok.type == TOK_PLUS) {
                if (left_type == right_type && (get_named_type(ref source, left_type) is !null)) {
                    return left_type;
                }
                return TYPE_STRING;
            }
            return TYPE_POISON;
        }
        return wir_binary_type(ref state, ref source, WirExpr(value=NO_WIR_VALUE, source_type=left_type), WirExpr(value=NO_WIR_VALUE, source_type=right_type), binary.left, binary.right);
    }
    if (node_tag(node) == NODE_CALL) {
        let call: CallNode = get_call_node(ref source.arena, node);
        let info: Optional(FuncInfo) = wir_direct_function(ref state, ref source, call.callee);
        if (!(info is !null)) { info = wir_generic_call_function(ref state, ref source, call); }
        if ((info is !null)) {
            if (call.preserve_fallible || !is_fallible_type(ref source, info.ret_type)) {
                return info.ret_type;
            }
            return get_inner_fallible_type(ref source, info.ret_type);
        }
        if (has_node(call.callee) && node_tag(call.callee) == NODE_FIELD_ACCESS) {
            let access: FieldAccessNode = get_field_access_node(ref source.arena, call.callee);
            let owner_type: Int = get_repr_type(ref source, wir_argument_type(ref state, ref source, access.obj));
            let owner: Optional(StructInfo) = null;
            owner = source.struct_id_map.lookup(owner_type);
            if ((owner is !null) && owner.is_class) {
                let meta_owner: StructInfo = owner;
                let target: Optional(FuncInfo) = null;
                let method_index: Int = 0;
                while (meta_owner.vtable is !null && method_index < meta_owner.vtable.length()) {
                    let method_info: FuncInfo = meta_owner.vtable[method_index];
                    if (method_info.base_name == access.field_name) {
                        target = method_info;
                        break;
                    }
                    method_index++;
                }
                if (!(target is !null)) {
                    target = source.func_table.lookup(meta_owner.name + "_" + access.field_name);
                }
                if ((target is !null)) {
                    if (call.preserve_fallible || !is_fallible_type(ref source, target.ret_type)) {
                        return target.ret_type;
                    }
                    return get_inner_fallible_type(ref source, target.ret_type);
                }
            }
        }

        let constructor_type: Int = wir_generic_constructor_type(ref state, ref source, call);
        if (constructor_type != 0) { return constructor_type; }

        // a call can also name a struct or class constructor. Asking for an
        // lvalue below would diagnose the type name as an unknown value before
        // the normal expression checker has a chance to instantiate it.
        let call_type: Int = get_expr_type(ref source, node);
        if (call_type != 0 && call_type != TYPE_POISON) {
            if (call.preserve_fallible || !is_fallible_type(ref source, call_type)) { return call_type; }
            return get_inner_fallible_type(ref source, call_type);
        }
        return TYPE_POISON;
    }
    let source_type: Int = wir_lvalue_type(ref state, ref source, node);
    if (source_type != TYPE_POISON) { return source_type; }
    source_type = get_expr_type(ref source, node);
    if (source_type == 0) { return TYPE_POISON; }
    return source_type;
}

func wir_generic_argument_type(ref state: WirFunctionLowering, ref source: Compiler, argument: ArgNode, parameter: ParamNode) -> Int {
    if (parameter.pass_mode == PARAM_REF && has_node(argument.val) && node_tag(argument.val) == NODE_REF) {
        return wir_lvalue_type(ref state, ref source, get_ref_node(ref source.arena, argument.val).node);
    }
    let actual_type: Int = wir_argument_type(ref state, ref source, argument.val);
    if (parameter.pass_mode == PARAM_REF) {
        let pointer: Optional(SymbolInfo) = source.ptr_base_map.lookup(actual_type);
        if ((pointer is !null)) { actual_type = pointer.type; }
    }
    if (!argument.is_spread || !parameter.is_variadic) { return actual_type; }

    let array: Optional(ArrayInfo) = source.array_info_map.lookup(get_repr_type(ref source, actual_type));
    if ((array is !null)) { return array.base_type; }
    let vector: Optional(SymbolInfo) = source.vector_base_map.lookup(get_repr_type(ref source, actual_type));
    if ((vector is !null)) { return vector.type; }
    return actual_type;
}

func wir_member_global(ref state: WirFunctionLowering, ref source: Compiler, object: NodeID, field_name: String) -> WirSourceGlobal {
    let path: Vector(String) = [];
    let root_node: NodeID = object;
    while (has_node(root_node) && node_tag(root_node) == NODE_FIELD_ACCESS) {
        let part: FieldAccessNode = get_field_access_node(ref source.arena, root_node);
        path.append(part.field_name);
        root_node = part.obj;
    }
    if (has_node(root_node) && node_tag(root_node) == NODE_VAR_ACCESS) {
        let root: String = get_var_access_node(ref source.arena, root_node).name_tok.value;
        if (!wir_has_local_binding(ref state, root)) {
            let name: String = "";
            let prefix: Optional(String) = source.current_file_visible_prefixes.lookup(root);
            if (prefix is !null && path.length() == 0 && !field_name.starts_with("__")) {
                name = prefix + field_name;
            }
            if (name.length() != 0) {
                let global: WirSourceGlobal = wir_source_global(ref source, name);
                if (has_wir_source_global(global)) { return global; }
            }
            let source_name: String = module_member_name(root + ".", path, field_name);
            let mapped: Optional(String) = source.current_file_global_aliases.lookup(source_name);
            if (mapped is !null) {
                let global: WirSourceGlobal = wir_source_global(ref source, mapped);
                if (has_wir_source_global(global)) { return global; }
            }
        }
    }
    return no_wir_source_global();
}

func wir_direct_global(ref state: WirFunctionLowering, ref source: Compiler, node: NodeID) -> WirSourceGlobal {
    if (!has_node(node)) {
        return no_wir_source_global();
    }
    if (node_tag(node) == NODE_VAR_ACCESS) {
        return wir_source_global(ref source, get_var_access_node(ref source.arena, node).name_tok.value);
    }
    if (node_tag(node) != NODE_FIELD_ACCESS) {
        return no_wir_source_global();
    }

    let access: FieldAccessNode = get_field_access_node(ref source.arena, node);
    let global: WirSourceGlobal = wir_member_global(ref state, ref source, access.obj, access.field_name);
    if (has_wir_source_global(global)) { return global; }
    return no_wir_source_global();
}

func wir_cast_target(ref source: Compiler, callee: NodeID) -> Int {
    let kind: Int = node_tag(callee);
    if (kind != NODE_VAR_ACCESS && kind != NODE_FIELD_ACCESS) { return 0; }
    let name: String = format_ast_path(ref source, callee);
    let target: Int = get_builtin_cast_target(name);
    if (target != 0) { return target; }
    target = get_cast_target(ref source, name);
    if (target != 0) { return target; }
    let alias: Optional(NamedTypeInfo) = find_named_decl(ref source, name);
    if (!(alias is !null) || !alias.is_alias) { return 0; }
    let underlying: Int = resolve_named_type(ref source, alias);
    if (is_conversion_target(ref source, underlying)) { return underlying; }
    return 0;
}

func wir_cast_needs_check(ref source: Compiler, source_type: Int, target_type: Int) -> Bool {
    if (source_type == target_type) { return false; }
    source_type = get_repr_type(ref source, source_type);
    target_type = get_repr_type(ref source, target_type);
    if (source_type == TYPE_ANY_ERROR) { source_type = TYPE_INT; }
    let info: Optional(StructInfo) = source.struct_id_map.lookup(source_type);
    if ((info is !null) && info.is_enum) { source_type = TYPE_INT; }
    if (target_type == TYPE_BOOL) {
        return source_type != TYPE_BOOL;
    }
    if (target_type == TYPE_CHAR) {
        return source_type != TYPE_CHAR && source_type != TYPE_BOOL;
    }
    if (source_type == TYPE_BOOL) { return false; }

    let source_float: Bool = source_type == TYPE_FLOAT || source_type == TYPE_FLOAT32;
    if (source_float && is_integer_type(target_type)) { return true; }
    if (!is_integer_type(source_type) || !is_integer_type(target_type)) { return false; }
    let source_bits: Int = get_type_bitwidth(source_type);
    let target_bits: Int = get_type_bitwidth(target_type);
    let source_unsigned: Bool = is_unsigned_integer(source_type);
    let target_unsigned: Bool = is_unsigned_integer(target_type);
    if (source_unsigned == target_unsigned) {
        return source_bits > target_bits;
    }
    if source_unsigned {
        return source_bits >= target_bits;
    }
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
    if (is_signed_integer(type_id)) {
        return wir_power_of_two(bits - 1) - UInt128(1U);
    }
    if (bits == 128) {
        return 340282366920938463463374607431768211455ULL;
    }
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
    let value_type: WirTypeID = wir_value_type(ref program, value.value);
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
        if source_signed {
            let non_negative: WirValueID = wir_binary(ref program, state.block, WirOpcode.SignedGreaterEqual, program.bool_type, value.value, zero, "", no_wir_location());
            valid = wir_bool_and(ref program, state.block, valid, non_negative);
        }
        if (source_bits >= 32) {
            let limit: WirValueID = wir_const_int(ref program, value_type, UInt128(1114111U));
            let opcode: WirOpcode = WirOpcode.UnsignedLessEqual;
            if source_signed { opcode = WirOpcode.SignedLessEqual; }
            let below_limit: WirValueID = wir_binary(ref program, state.block, opcode, program.bool_type, value.value, limit, "", no_wir_location());
            valid = wir_bool_and(ref program, state.block, valid, below_limit);
        }
        if (source_bits >= 32 || (source_unsigned && source_bits >= 16)) {
            let low: WirValueID = wir_const_int(ref program, value_type, UInt128(55296U));
            let high: WirValueID = wir_const_int(ref program, value_type, UInt128(57343U));
            let less: WirOpcode = WirOpcode.UnsignedLess;
            let greater: WirOpcode = WirOpcode.UnsignedGreater;
            if source_signed {
                less = WirOpcode.SignedLess;
                greater = WirOpcode.SignedGreater;
            }
            let below: WirValueID = wir_binary(ref program, state.block, less, program.bool_type, value.value, low, "", no_wir_location());
            let above: WirValueID = wir_binary(ref program, state.block, greater, program.bool_type, value.value, high, "", no_wir_location());
            valid = wir_bool_and(ref program, state.block, valid, wir_bool_or(ref program, state.block, below, above));
        }
        if (valid == NO_WIR_VALUE) {
            return wir_const_bool(ref program, true);
        }
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
        if source_signed { upper = WirOpcode.SignedLessEqual; }
        valid = wir_binary(ref program, state.block, upper, program.bool_type, value.value, maximum, "", no_wir_location());
        if source_signed {
            let minimum_magnitude: UInt128 = wir_power_of_two(target_bits - 1);
            let minimum: WirValueID = wir_const_int(ref program, value_type, wir_negative_bits(source_bits, minimum_magnitude));
            let above_min: WirValueID = wir_binary(ref program, state.block, WirOpcode.SignedGreaterEqual, program.bool_type, value.value, minimum, "", no_wir_location());
            valid = wir_bool_and(ref program, state.block, valid, above_min);
        }
    }
    if (valid == NO_WIR_VALUE) {
        return wir_const_bool(ref program, true);
    }
    return valid;
}

func wir_float_cast_condition(ref state: WirFunctionLowering, ref source: Compiler, ref program: WirModule, value: WirExpr, target_type: Int) -> WirValueID {
    target_type = get_repr_type(ref source, target_type);
    let value_type: WirTypeID = wir_value_type(ref program, value.value);
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

func wir_fail(ref program: WirModule, block: WirBlockID, name: String) -> Void {
    let function_id: WirFuncID = wir_find_function(program, name);
    if (function_id == NO_WIR_FUNC) {
        wir_trap(ref program, block, no_wir_location());
        return;
    }
    wir_call(ref program, block, wir_function_value(ref program, function_id), [], "", no_wir_location());
    wir_append(ref program, block, WirOpcode.Unreachable, program.void_type, [], [], no_wir_location());
}

func wir_guard_runtime(ref state: WirFunctionLowering, ref program: WirModule, valid: WirValueID, failure: String) -> Void {
    let success: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "guard.ok."), []);
    let failed: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "guard.fail."), []);
    wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [valid], [wir_edge(success, []), wir_edge(failed, [])], no_wir_location());
    wir_fail(ref program, failed, failure);
    state.block = success;
}

func wir_guard_signed_div(ref state: WirFunctionLowering, ref program: WirModule, left: WirValueID, right: WirValueID, type_id: WirTypeID) -> Void {
    let type: WirType = program.arena.types[wir_id_index(UInt32(type_id))];
    if (type.kind != WirTypeKind.SignedInt || type.bits <= 0 || type.bits > 128) {
        return;
    }

    // idiv cannot represent MIN / -1. LLVM treats the same operation as poison,
    // so keep this check in WIR where every backend gets the same behavior.
    let sign: UInt128 = UInt128(1U) << UInt128(type.bits - 1);
    let mask: UInt128 = ~UInt128(0U);
    if (type.bits < 128) { mask = (UInt128(1U) << UInt128(type.bits)) - UInt128(1U); }
    let minimum: WirValueID = wir_const_int(ref program, type_id, sign);
    let negative_one: WirValueID = wir_const_int(ref program, type_id, mask);
    let is_minimum: WirValueID = wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, left, minimum, "", no_wir_location());
    let is_negative_one: WirValueID = wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, right, negative_one, "", no_wir_location());
    let overflow: WirValueID = wir_bool_and(ref program, state.block, is_minimum, is_negative_one);
    let valid: WirValueID = wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, overflow, wir_const_bool(ref program, false), "", no_wir_location());
    wir_guard_runtime(ref state, ref program, valid, "__wl_fail_overflow");
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
    while (i < source.error_types.length()) {
        let info: StructInfo = source.error_types[i];
        if (info.compiler_link_name == "Error") {
            let field: Optional(FieldInfo) = find_field(info, "Overflow");
            if ((field is !null)) {
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

func wir_lower_fallible_cast(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    value: WirExpr,
    target_type: Int,
    valid: WirValueID
) -> WirExpr {
    let source_type: Int = get_fallible_type_id(ref source, target_type);
    let result_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
    if (result_type == NO_WIR_TYPE) { return wir_no_expr(); }

    let success: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "cast.ok."), []);
    let failure: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "cast.fail."), []);
    let merge: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "cast.end."), [wir_param("value", result_type)]);
    wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [valid], [wir_edge(success, []), wir_edge(failure, [])], no_wir_location());

    state.block = failure;
    let error_value: WirValueID = wir_overflow_error(ref state, ref types, ref source, ref program);
    if (error_value == NO_WIR_VALUE) {
        return wir_no_expr();
    }
    let failed: WirValueID = wir_make_error_result(ref types, ref source, ref program, state.block, source_type, error_value);
    if (failed == NO_WIR_VALUE) {
        return wir_no_expr();
    }
    wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(merge, [failed])], no_wir_location());

    state.block = success;
    let converted: WirExpr = wir_cast_expr(ref state, ref types, ref source, ref program, value, target_type, false, no_position());
    if (converted.value == NO_WIR_VALUE) {
        return wir_no_expr();
    }
    let succeeded: WirValueID = wir_make_success_result(ref types, ref source, ref program, state.block, source_type, converted);
    if (succeeded == NO_WIR_VALUE) { return wir_no_expr(); }
    wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(merge, [succeeded])], no_wir_location());

    state.block = merge;
    let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(merge))];
    return WirExpr(value=block.parameters[0], source_type=source_type);
}

func wir_lower_throw(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: ThrowNode) -> Void {
    let value: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, node.value);
    if (value.value == NO_WIR_VALUE) {
        return;
    }
    if (value.source_type != TYPE_ANY_ERROR && !is_error_type(ref source, get_repr_type(ref source, value.source_type))) {
        throw_type_error(node.pos, "Cannot throw " + get_type_name(ref source, value.source_type) + ", expected an error value");
        return;
    }
    let error_value: WirValueID = wir_error_value(ref state, ref types, ref source, ref program, value);
    if (error_value == NO_WIR_VALUE) {
        return;
    }
    wir_route_error(ref state, ref types, ref source, ref program, error_value);
}

func wir_route_error(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, error_value: WirValueID) -> Void {
    if (state.error_targets.length() != 0) {
        let target: WirErrorTarget = state.error_targets[state.error_targets.length() - 1];
        wir_cleanup_temporaries(ref state, ref types, ref source, ref program, target.owned_count);
        wir_cleanup_bindings(ref state, ref types, ref source, ref program, target.binding_count);
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
            wir_cleanup_temporaries(ref state, ref types, ref source, ref program, 0);
            wir_cleanup_bindings(ref state, ref types, ref source, ref program, 0);
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
    let value: WirExpr = wir_no_expr();
    if (has_node(node.expr) && node_tag(node.expr) == NODE_INDEX_ACCESS) {
        value = wir_lower_index_expr(ref state, ref types, ref source, ref program, get_index_access_node(ref source.arena, node.expr), true);
    } else {
        value = wir_lower_expr(ref state, ref types, ref source, ref program, node.expr);
    }
    if (value.value == NO_WIR_VALUE) {
        return wir_no_expr();
    }
    if (!is_fallible_type(ref source, value.source_type)) {
        let target_name: String = "";
        if (has_node(node.expr) && node_tag(node.expr) == NODE_CALL) {
            let call: CallNode = get_call_node(ref source.arena, node.expr);
            if (has_node(call.callee) && node_tag(call.callee) == NODE_VAR_ACCESS) {
                let callee: VarAccessNode = get_var_access_node(ref source.arena, call.callee);
                let target_type: Int = get_cast_target(ref source, callee.name_tok.value);
                if (target_type != 0) {
                    target_name = get_type_name(ref source, target_type);
                }
            }
        }
        if (target_name.length() != 0) {
            throw_invalid_syntax(node.pos, "Conversion to " + target_name + " cannot fail; remove '?'");
        } else {
            throw_invalid_syntax(node.pos, "Cannot use '?' on a non-fallible type.");
        }
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
    if owns_result {
        wir_take_owned(ref state, value.value);
    }
    state.block = success;
    state.terminated = false;
    if (inner_type == TYPE_VOID) {
        return WirExpr(value=NO_WIR_VALUE, source_type=TYPE_VOID);
    }
    let result: WirValueID = wir_field(ref program, state.block, value.value, 2, "", no_wir_location());
    if (owns_result && wir_value_needs_drop(ref source, inner_type)) {
        wir_track_owned(ref state, result, inner_type);
    }
    return WirExpr(value=result, source_type=inner_type);
}

func wir_unwrap_conversion(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirExpr, target_type: Int) -> WirExpr {
    let failed: WirValueID = wir_field(ref program, state.block, value.value, 0, "", no_wir_location());
    let failure: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "convert.fail."), []);
    let success: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "convert.ok."), []);
    wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [failed], [wir_edge(failure, []), wir_edge(success, [])], no_wir_location());

    let saved_owned: Vector(WirOwnedValue) = wir_copy_owned(state.owned_values);
    let owns_result: Bool = wir_take_owned(ref state, value.value);
    state.block = failure;
    wir_cleanup_temporaries(ref state, ref types, ref source, ref program, 0);
    wir_trap(ref program, state.block, no_wir_location());

    state.owned_values = saved_owned;
    if owns_result {
        wir_take_owned(ref state, value.value);
    }
    state.block = success;
    let result: WirValueID = wir_field(ref program, state.block, value.value, 2, "", no_wir_location());
    if (owns_result && wir_value_needs_drop(ref source, target_type)) {
        wir_track_owned(ref state, result, target_type);
    }
    return WirExpr(value=result, source_type=target_type);
}

func wir_lower_catch(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: CatchNode) -> Void {
    if (has_node(node.stmt) && node_tag(node.stmt) == NODE_VAR_DECL) {
        let pending: VarDeclareNode = get_var_decl_node(ref source.arena, node.stmt);
        let pending_type: Int = TYPE_AUTO;
        if (has_node(pending.type_node)) { pending_type = resolve_type(ref source, pending.type_node); }
        if (pending_type == TYPE_AUTO) {
            pending_type = wir_argument_type(ref state, ref source, pending.value);
            if (pending_type == TYPE_POISON || pending_type == TYPE_AUTO) {
                pending_type = get_expr_type(ref source, pending.value);
            }
            if (is_fallible_type(ref source, pending_type)) {
                pending_type = get_inner_fallible_type(ref source, pending_type);
            }
        }
        let pending_wir: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, pending_type);
        if (pending_wir == NO_WIR_TYPE) { return; }
        let pending_address: WirValueID = wir_stack_alloc(ref program, state.entry, pending_wir, pending.name_tok.value + ".addr", no_wir_location());
        wir_store(ref program, state.block, wir_const_zero(ref program, pending_wir), pending_address, no_wir_location());
        state.bindings.append(WirBinding(name=pending.name_tok.value, source_type=pending_type, address=pending_address, is_const=pending.is_const, owns_value=wir_value_needs_drop(ref source, pending_type), pending_init=true, is_const_access=false, is_reference=false));
    }
    let parent_binding_count: Int = state.bindings.length();
    let parent_owned: Vector(WirOwnedValue) = wir_copy_owned(state.owned_values);
    let error_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, TYPE_ANY_ERROR);
    if (error_type == NO_WIR_TYPE) {
        return;
    }
    let error_address: WirValueID = wir_stack_alloc(ref program, state.entry, error_type, node.err_name.value + ".addr", no_wir_location());
    let failure: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "catch."), []);
    let merge: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "catch.end."), []);
    state.error_targets.append(WirErrorTarget(block=failure, address=error_address, binding_count=parent_binding_count, owned_count=state.owned_values.length()));

    wir_lower_stmt(ref state, ref types, ref source, ref program, node.stmt);
    if (!state.terminated) {
        // argument temporaries belong to this path, the catch edge never defined them.
        // finish their cleanup before joining, including any blocks emitted by drop glue.
        wir_cleanup_temporaries(ref state, ref types, ref source, ref program, parent_owned.length());
    }
    let normal_end: WirBlockID = state.block;
    let normal_terminated: Bool = state.terminated;
    let normal_bindings: Vector(WirBinding) = wir_copy_bindings(state.bindings);
    let normal_owned: Vector(WirOwnedValue) = wir_copy_owned(state.owned_values);
    wir_pop_error_target(ref state);
    if (!normal_terminated) {
        wir_append(ref program, normal_end, WirOpcode.Jump, program.void_type, [], [wir_edge(merge, [])], no_wir_location());
    }

    wir_restore_bindings(ref state, parent_binding_count);
    state.owned_values = wir_copy_owned(parent_owned);
    state.bindings.append(WirBinding(name=node.err_name.value, source_type=TYPE_ANY_ERROR, address=error_address, is_const=false, owns_value=false, pending_init=false, is_const_access=false, is_reference=false));
    state.block = failure;
    state.terminated = false;
    wir_lower_block(ref state, ref types, ref source, ref program, node.body);
    let catch_end: WirBlockID = state.block;
    let catch_terminated: Bool = state.terminated;
    let catch_owned: Vector(WirOwnedValue) = wir_copy_owned(state.owned_values);
    if (!catch_terminated) {
        wir_append(ref program, catch_end, WirOpcode.Jump, program.void_type, [], [wir_edge(merge, [])], no_wir_location());
    }

    if (normal_terminated && catch_terminated) {
        state.terminated = true;
        return;
    }
    state.block = merge;
    state.terminated = false;
    if (!normal_terminated) {
        state.bindings = normal_bindings;
        state.binding_indices = null;
        state.indexed_bindings = 0;
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
    state.binding_indices = null;
    state.indexed_bindings = 0;
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

func wir_lower_runtime_arithmetic(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    left: WirExpr,
    right: WirExpr,
    source_type: Int,
    token: Int
) -> WirExpr {
    let repr_type: Int = get_repr_type(ref source, source_type);
    let hook_name: String = "";
    let call_left: WirExpr = left;
    let call_right: WirExpr = right;
    let call_type: Int = source_type;

    if ((repr_type == TYPE_FLOAT || repr_type == TYPE_FLOAT32) && token == TOK_MOD) {
        hook_name = "float_mod";
        call_type = TYPE_FLOAT;
        call_left = wir_cast_expr(ref state, ref types, ref source, ref program, left, TYPE_FLOAT, false, no_position());
        call_right = wir_cast_expr(ref state, ref types, ref source, ref program, right, TYPE_FLOAT, false, no_position());
    } else if ((repr_type == TYPE_INT128 || repr_type == TYPE_UINT128) && (token == TOK_DIV || token == TOK_MOD)) {
        if (repr_type == TYPE_INT128) {
            if (token == TOK_DIV) { hook_name = "int128_div"; }
            else { hook_name = "int128_rem"; }
        } else {
            if (token == TOK_DIV) { hook_name = "uint128_div"; }
            else { hook_name = "uint128_rem"; }
        }
    } else {
        return wir_no_expr();
    }

    if (call_left.value == NO_WIR_VALUE || call_right.value == NO_WIR_VALUE) {
        return wir_no_expr();
    }
    let target: Optional(FuncInfo) = wir_compiler_link_function(ref source, hook_name);
    if (!(target is !null)) {
        state.errors.append("Arithmetic runtime function '" + hook_name + "' is unavailable during WIR lowering");
        return wir_no_expr();
    }
    let function_id: WirFuncID = wir_find_function(program, target.name);
    if (function_id == NO_WIR_FUNC) {
        function_id = wir_lower_function_decl(ref types, ref source, ref program, target);
    }
    if (function_id == NO_WIR_FUNC) {
        return wir_no_expr();
    }

    let result: WirValueID = wir_call(ref program, state.block, wir_function_value(ref program, function_id), [call_left.value, call_right.value], "", no_wir_location());
    let lowered: WirExpr = WirExpr(value=result, source_type=call_type);
    if (repr_type == TYPE_FLOAT32) {
        return wir_cast_expr(ref state, ref types, ref source, ref program, lowered, source_type, false, no_position());
    }
    return WirExpr(value=result, source_type=source_type);
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
    if (target_type == TYPE_FLOAT && (source_type == TYPE_INT || source_type == TYPE_LONG || source_type == TYPE_FLOAT32)) {
        return true;
    }
    return false;
}

func wir_unbox_variant(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirExpr, target_type: Int) -> WirExpr {
    let variant: Optional(StructInfo) = source.struct_id_map.lookup(get_repr_type(ref source, value.source_type));
    if (!(variant is !null) || variant.name != "$Variant") {
        return wir_no_expr();
    }

    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [value.value], [], no_wir_location());
    let tag_slot: WirValueID = wir_field_address(ref program, state.block, value.value, 0, "", no_wir_location());
    let tag: WirValueID = wir_load(ref program, state.block, tag_slot, "", no_wir_location());
    let tag_type: WirTypeID = wir_unsigned_int_type(ref program, 64);
    let expected_tag: WirValueID = wir_const_int(ref program, tag_type, UInt128(type_fingerprint(ref source, target_type)));
    let matches: WirValueID = wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, tag, expected_tag, "", no_wir_location());
    // a stored null has a box with tag zero, get already distinguishes it from a missing key
    if (is_nullable_reference_type(ref source, target_type)) {
        let null_tag: WirValueID = wir_const_int(ref program, tag_type, UInt128(0U));
        let stored_null: WirValueID = wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, tag, null_tag, "", no_wir_location());
        matches = wir_bool_or(ref program, state.block, matches, stored_null);
    }
    wir_guard_runtime(ref state, ref program, matches, "__wl_fail_erased_type");

    let low_slot: WirValueID = wir_field_address(ref program, state.block, value.value, 1, "", no_wir_location());
    let low: WirValueID = wir_load(ref program, state.block, low_slot, "", no_wir_location());
    let target_wir: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, target_type);
    if (target_wir == NO_WIR_TYPE) {
        return wir_no_expr();
    }
    let target_info: Optional(StructInfo) = source.struct_id_map.lookup(get_repr_type(ref source, target_type));
    if ((target_info is !null) && target_info.is_interface) {
        let high_slot: WirValueID = wir_field_address(ref program, state.block, value.value, 2, "", no_wir_location());
        let high: WirValueID = wir_load(ref program, state.block, high_slot, "", no_wir_location());
        let interface_wir: WirType = program.arena.types[wir_id_index(UInt32(target_wir))];
        let object: WirValueID = wir_cast(ref program, state.block, low, interface_wir.fields[0], "", no_wir_location());
        let table: WirValueID = wir_cast(ref program, state.block, high, interface_wir.fields[1], "", no_wir_location());
        let result: WirValueID = wir_struct_value(ref program, state.block, target_wir, [object, table], "", no_wir_location());
        wir_retain(ref program, state.block, object, no_wir_location());
        wir_track_owned(ref state, result, target_type);
        return WirExpr(value=result, source_type=target_type);
    }
    if (is_value_struct(ref source, target_type)) {
        let pointer: WirValueID = wir_cast(ref program, state.block, low, wir_pointer_type(ref program, target_wir), "", no_wir_location());
        let result: WirValueID = wir_load(ref program, state.block, pointer, "", no_wir_location());
        if (wir_value_needs_drop(ref source, target_type)) {
            wir_emit_ownership_value(ref state, ref types, ref source, ref program, result, target_type, true);
            wir_track_owned(ref state, result, target_type);
        }
        return WirExpr(value=result, source_type=target_type);
    }
    if (target_type == TYPE_INT128 || target_type == TYPE_UINT128) {
        let high_slot: WirValueID = wir_field_address(ref program, state.block, value.value, 2, "", no_wir_location());
        let high: WirValueID = wir_load(ref program, state.block, high_slot, "", no_wir_location());
        let word_type: WirTypeID = wir_unsigned_int_type(ref program, 64);
        let wide_type: WirTypeID = wir_unsigned_int_type(ref program, 128);
        let low_word: WirValueID = wir_cast(ref program, state.block, low, word_type, "", no_wir_location());
        let high_word: WirValueID = wir_cast(ref program, state.block, high, word_type, "", no_wir_location());
        let wide_low: WirValueID = wir_cast(ref program, state.block, low_word, wide_type, "", no_wir_location());
        let wide_high: WirValueID = wir_cast(ref program, state.block, high_word, wide_type, "", no_wir_location());
        let shifted: WirValueID = wir_binary(
            ref program,
            state.block,
            WirOpcode.ShiftLeft,
            wide_type,
            wide_high,
            wir_const_int(ref program, wide_type, UInt128(64U)),
            "",
            no_wir_location()
        );
        let combined: WirValueID = wir_binary(ref program, state.block, WirOpcode.BitOr, wide_type, wide_low, shifted, "", no_wir_location());
        return WirExpr(value=wir_cast(ref program, state.block, combined, target_wir, "", no_wir_location()), source_type=target_type);
    }
    let target_kind: WirTypeKind = program.arena.types[wir_id_index(UInt32(target_wir))].kind;
    if (target_kind == WirTypeKind.Pointer) {
        let result: WirValueID = wir_cast(ref program, state.block, low, target_wir, "", no_wir_location());
        let lowered: WirExpr = WirExpr(value=result, source_type=target_type);
        if (wir_value_needs_drop(ref source, target_type)) {
            wir_emit_ownership_value(ref state, ref types, ref source, ref program, result, target_type, true);
            wir_track_owned(ref state, result, target_type);
        }
        return lowered;
    }
    if ((target_kind == WirTypeKind.BoolType || target_kind == WirTypeKind.SignedInt || target_kind == WirTypeKind.UnsignedInt) && program.arena.types[wir_id_index(UInt32(target_wir))].bits <= 64) {
        return WirExpr(value=wir_cast(ref program, state.block, low, target_wir, "", no_wir_location()), source_type=target_type);
    }
    if (target_type == TYPE_FLOAT) {
        return WirExpr(value=wir_unary(ref program, state.block, WirOpcode.Bitcast, target_wir, low, "", no_wir_location()), source_type=target_type);
    }
    if (target_type == TYPE_FLOAT32) {
        let float_type: WirTypeID = wir_float_type(ref program, 64);
        let wide: WirValueID = wir_unary(ref program, state.block, WirOpcode.Bitcast, float_type, low, "", no_wir_location());
        return WirExpr(value=wir_cast(ref program, state.block, wide, target_wir, "", no_wir_location()), source_type=target_type);
    }
    state.errors.append("Variant payload for " + get_type_name(ref source, target_type) + " is not lowered to WIR yet");
    return wir_no_expr();
}

func wir_variant_drop_function(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, variant_type: Int) -> WirFuncID {
    let name: String = "__wl_drop." + variant_type;
    let existing: WirFuncID = wir_find_function(program, name);
    if (existing != NO_WIR_FUNC) { return existing; }

    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let variant_wir: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, variant_type);
    let tag_type: WirTypeID = wir_unsigned_int_type(ref program, 64);
    let function_id: WirFuncID = wir_add_function(ref program, name, [wir_param("object", raw_pointer)], program.void_type, false, WirLinkage.Internal, WirABI.White);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let release: WirBlockID = wir_add_block(ref program, function_id, "release", []);
    let done: WirBlockID = wir_add_block(ref program, function_id, "done", []);
    let object: WirValueID = wir_cast(ref program, entry, function.parameters[0], variant_wir, "variant", no_wir_location());
    let tag: WirValueID = wir_load(ref program, entry, wir_field_address(ref program, entry, object, 0, "", no_wir_location()), "tag", no_wir_location());

    let seen: Dict(String, Bool) = Dict();
    let check: WirBlockID = entry;
    let type_id: Int = 1;
    while (type_id < source.type_counter) {
        if (type_id != variant_type && (is_ref_type(ref source, type_id) || is_value_struct(ref source, type_id))) {
            let fingerprint: UInt64 = type_fingerprint(ref source, type_id);
            let fingerprint_key: String = "" + fingerprint;
            if (!seen.contains_key(fingerprint_key)) {
                seen.put(fingerprint_key, true);
                let next: WirBlockID = wir_add_block(ref program, function_id, "check." + type_id, []);
                let matches: WirValueID = wir_binary(
                    ref program,
                    check,
                    WirOpcode.Equal,
                    program.bool_type,
                    tag,
                    wir_const_int(ref program, tag_type, UInt128(fingerprint)),
                    "matches",
                    no_wir_location()
                );
                wir_append(ref program, check, WirOpcode.Branch, program.void_type, [matches], [wir_edge(release, []), wir_edge(next, [])], no_wir_location());
                check = next;
            }
        }
        type_id++;
    }
    wir_append(ref program, check, WirOpcode.Jump, program.void_type, [], [wir_edge(done, [])], no_wir_location());

    let low: WirValueID = wir_load(ref program, release, wir_field_address(ref program, release, object, 1, "", no_wir_location()), "payload", no_wir_location());
    wir_release(ref program, release, wir_cast(ref program, release, low, raw_pointer, "value", no_wir_location()), no_wir_location());
    wir_append(ref program, release, WirOpcode.Jump, program.void_type, [], [wir_edge(done, [])], no_wir_location());
    wir_return(ref program, done, NO_WIR_VALUE, no_wir_location());
    return function_id;
}

func wir_box_variant(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirExpr, variant: StructInfo) -> WirExpr {
    let boxed_type: Int = get_repr_type(ref source, value.source_type);
    let boxed_info: Optional(StructInfo) = source.struct_id_map.lookup(boxed_type);
    let boxed_enum: Bool = (boxed_info is !null) && boxed_info.is_enum;
    let supported: Bool = value.source_type == TYPE_NULL || value.source_type == TYPE_NULLPTR ||
                          is_primitive_type(boxed_type) || is_ref_type(ref source, value.source_type) ||
                          is_pointer_type(ref source, value.source_type) || is_value_struct(ref source, value.source_type) || boxed_enum;
    if (!supported) {
        state.errors.append("Type " + get_type_name(ref source, value.source_type) + " cannot be stored in Dict");
        return wir_no_expr();
    }

    let allocator: Optional(FuncInfo) = wir_compiler_link_function(ref source, "memory_alloc");
    if (!(allocator is !null)) {
        state.errors.append("Variant boxing requires the memory_alloc compiler link");
        return wir_no_expr();
    }
    let allocator_id: WirFuncID = wir_find_function(program, allocator.name);
    if (allocator_id == NO_WIR_FUNC) {
        allocator_id = wir_lower_function_decl(ref types, ref source, ref program, allocator);
    }
    if (allocator_id == NO_WIR_FUNC) {
        return wir_no_expr();
    }

    let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let variant_wir: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, variant.type_id);
    let total_size: UInt64 = UInt64(variant_payload_size() + WIR_OBJECT_HEADER_SIZE);
    let raw: WirValueID = wir_call(
        ref program,
        state.block,
        wir_function_value(ref program, allocator_id),
        [wir_const_int(ref program, size_type, UInt128(total_size))],
        "",
        no_wir_location()
    );
    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [raw], [], no_wir_location());

    let drop_id: WirFuncID = wir_variant_drop_function(ref types, ref source, ref program, variant.type_id);
    let drop_address: WirValueID = wir_const_address(ref program, raw_pointer, wir_function_value(ref program, drop_id), 0L);
    let drop_slot: WirValueID = wir_cast(ref program, state.block, raw, wir_pointer_type(ref program, raw_pointer), "", no_wir_location());
    wir_store(ref program, state.block, drop_address, drop_slot, no_wir_location());

    let uint32_type: WirTypeID = wir_unsigned_int_type(ref program, 32);
    let refcount_slot: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE + WIR_ARC_REFCOUNT_OFFSET, wir_pointer_type(ref program, uint32_type));
    let type_slot: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE + WIR_ARC_TYPE_OFFSET, wir_pointer_type(ref program, uint32_type));
    wir_store(ref program, state.block, wir_const_int(ref program, uint32_type, UInt128(1U)), refcount_slot, no_wir_location());
    wir_store(ref program, state.block, wir_const_int(ref program, uint32_type, UInt128(UInt32(variant.type_id))), type_slot, no_wir_location());

    let object: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE, variant_wir);
    let tag_type: WirTypeID = wir_unsigned_int_type(ref program, 64);
    let payload_type: WirTypeID = wir_signed_int_type(ref program, 64);
    let tag: UInt64 = type_fingerprint(ref source, value.source_type);
    if (value.source_type == TYPE_NULL || value.source_type == TYPE_NULLPTR) { tag = UInt64(0); }
    let low: WirValueID = wir_const_int(ref program, payload_type, UInt128(0U));
    let high: WirValueID = wir_const_int(ref program, payload_type, UInt128(0U));

    if (value.source_type != TYPE_NULL && value.source_type != TYPE_NULLPTR) {
        if ((boxed_info is !null) && boxed_info.is_interface) {
            let object_pointer: WirValueID = wir_field(ref program, state.block, value.value, 0, "", no_wir_location());
            let table_pointer: WirValueID = wir_field(ref program, state.block, value.value, 1, "", no_wir_location());
            low = wir_cast(ref program, state.block, object_pointer, payload_type, "", no_wir_location());
            high = wir_cast(ref program, state.block, table_pointer, payload_type, "", no_wir_location());
            if (!wir_take_owned(ref state, value.value)) {
                wir_retain(ref program, state.block, object_pointer, no_wir_location());
            }
        } else if (is_value_struct(ref source, value.source_type)) {
            let erased: WirExpr = wir_erase_struct(ref state, ref types, ref source, ref program, value);
            if (erased.value == NO_WIR_VALUE) {
                return wir_no_expr();
            }
            wir_take_owned(ref state, erased.value);
            low = wir_cast(ref program, state.block, erased.value, payload_type, "", no_wir_location());
        } else if (boxed_type == TYPE_INT128 || boxed_type == TYPE_UINT128) {
            let i128_type: WirTypeID = wir_unsigned_int_type(ref program, 128);
            let wide: WirValueID = value.value;
            if (wir_value_type(ref program, wide) != i128_type) {
                wide = wir_cast(ref program, state.block, wide, i128_type, "", no_wir_location());
            }
            low = wir_cast(ref program, state.block, wide, payload_type, "", no_wir_location());
            let shifted: WirValueID = wir_binary(
                ref program,
                state.block,
                WirOpcode.UnsignedShiftRight,
                i128_type,
                wide,
                wir_const_int(ref program, i128_type, UInt128(64U)),
                "",
                no_wir_location()
            );
            high = wir_cast(ref program, state.block, shifted, payload_type, "", no_wir_location());
        } else if (boxed_type == TYPE_FLOAT32) {
            let float_type: WirTypeID = wir_float_type(ref program, 64);
            let extended: WirValueID = wir_cast(ref program, state.block, value.value, float_type, "", no_wir_location());
            low = wir_unary(ref program, state.block, WirOpcode.Bitcast, payload_type, extended, "", no_wir_location());
        } else if (boxed_type == TYPE_FLOAT) {
            low = wir_unary(ref program, state.block, WirOpcode.Bitcast, payload_type, value.value, "", no_wir_location());
        } else if (is_pointer_type(ref source, value.source_type) || is_ref_type(ref source, value.source_type)) {
            let pointer: WirValueID = value.value;
            if ((boxed_info is !null) && boxed_info.is_interface) {
                pointer = wir_field(ref program, state.block, value.value, 0, "", no_wir_location());
            }
            low = wir_cast(ref program, state.block, pointer, payload_type, "", no_wir_location());
            if (is_ref_type(ref source, value.source_type)) {
                if (!wir_take_owned(ref state, value.value)) {
                    wir_retain(ref program, state.block, pointer, no_wir_location());
                }
            }
        } else {
            low = wir_cast(ref program, state.block, value.value, payload_type, "", no_wir_location());
        }
    }

    wir_store(
        ref program,
        state.block,
        wir_const_int(ref program, tag_type, UInt128(tag)),
        wir_field_address(ref program, state.block, object, 0, "", no_wir_location()),
        no_wir_location()
    );
    wir_store(ref program, state.block, low, wir_field_address(ref program, state.block, object, 1, "", no_wir_location()), no_wir_location());
    wir_store(ref program, state.block, high, wir_field_address(ref program, state.block, object, 2, "", no_wir_location()), no_wir_location());
    wir_track_owned(ref state, object, variant.type_id);
    return WirExpr(value=object, source_type=variant.type_id);
}

func wir_erased_struct_drop_name(source_type: Int) -> String {
    return "__wl_drop.erased." + source_type;
}

func wir_erased_struct_drop_function(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, source_type: Int) -> WirFuncID {
    let name: String = wir_erased_struct_drop_name(source_type);
    let function_id: WirFuncID = wir_find_function(program, name);
    if (function_id != NO_WIR_FUNC) { return function_id; }

    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let value_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
    if (value_type == NO_WIR_TYPE) { return NO_WIR_FUNC; }

    function_id = wir_add_function(ref program, name, [wir_param("object", raw_pointer)], program.void_type, false, WirLinkage.Internal, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let object: WirValueID = wir_cast(ref program, entry, function.parameters[0], wir_pointer_type(ref program, value_type), "", no_wir_location());
    let drop_state: WirFunctionLowering = WirFunctionLowering(
        function=function_id,
        return_type=TYPE_VOID,
        entry=entry,
        block=entry,
        bindings=[],
        loops=[],
        error_targets=[],
        owned_values=[],
        errors=[],
        terminated=false,
        next_block=0,
        binding_indices=null,
        indexed_bindings=0,
        reference_checked=false
    );
    wir_emit_ownership_slot(ref drop_state, ref types, ref source, ref program, object, source_type, false);

    let i: Int = 0;
    while (i < drop_state.errors.length()) {
        types.errors.append(drop_state.errors[i]);
        i++;
    }
    wir_return(ref program, drop_state.block, NO_WIR_VALUE, no_wir_location());
    return function_id;
}

func wir_erase_struct(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirExpr) -> WirExpr {
    let value_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, value.source_type);
    if (value_type == NO_WIR_TYPE) { return wir_no_expr(); }
    let layout: WirTypeLayout = wir_lowering_layout(ref types, program, value_type);
    if (!layout.valid || layout.size > UInt64(wir_max_object_size(program.data_layout)) - UInt64(WIR_OBJECT_HEADER_SIZE)) {
        state.errors.append("Struct layout is too large for erased storage");
        return wir_no_expr();
    }

    let allocator: Optional(FuncInfo) = wir_compiler_link_function(ref source, "memory_alloc");
    if (!(allocator is !null)) {
        state.errors.append("Struct erasure requires the memory_alloc compiler link");
        return wir_no_expr();
    }
    let allocator_id: WirFuncID = wir_find_function(program, allocator.name);
    if (allocator_id == NO_WIR_FUNC) {
        allocator_id = wir_lower_function_decl(ref types, ref source, ref program, allocator);
    }
    if (allocator_id == NO_WIR_FUNC) {
        return wir_no_expr();
    }

    let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let total_size: UInt64 = layout.size + UInt64(WIR_OBJECT_HEADER_SIZE);
    let raw: WirValueID = wir_call(
        ref program,
        state.block,
        wir_function_value(ref program, allocator_id),
        [wir_const_int(ref program, size_type, UInt128(total_size))],
        "",
        no_wir_location()
    );
    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [raw], [], no_wir_location());

    let drop_id: WirFuncID = wir_erased_struct_drop_function(ref types, ref source, ref program, value.source_type);
    if (drop_id == NO_WIR_FUNC) {
        return wir_no_expr();
    }
    let drop_address: WirValueID = wir_const_address(ref program, raw_pointer, wir_function_value(ref program, drop_id), 0L);
    let drop_slot: WirValueID = wir_cast(ref program, state.block, raw, wir_pointer_type(ref program, raw_pointer), "", no_wir_location());
    wir_store(ref program, state.block, drop_address, drop_slot, no_wir_location());

    let uint32_type: WirTypeID = wir_unsigned_int_type(ref program, 32);
    let refcount_slot: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE + WIR_ARC_REFCOUNT_OFFSET, wir_pointer_type(ref program, uint32_type));
    let type_slot: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE + WIR_ARC_TYPE_OFFSET, wir_pointer_type(ref program, uint32_type));
    wir_store(ref program, state.block, wir_const_int(ref program, uint32_type, UInt128(1U)), refcount_slot, no_wir_location());
    wir_store(ref program, state.block, wir_const_int(ref program, uint32_type, UInt128(UInt32(value.source_type))), type_slot, no_wir_location());

    let payload: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE, wir_pointer_type(ref program, value_type));
    if (wir_value_needs_drop(ref source, value.source_type) && !wir_take_owned(ref state, value.value)) {
        wir_emit_ownership_value(ref state, ref types, ref source, ref program, value.value, value.source_type, true);
    }
    wir_store(ref program, state.block, value.value, payload, no_wir_location());
    let erased: WirValueID = wir_cast(ref program, state.block, payload, raw_pointer, "", no_wir_location());
    wir_track_owned(ref state, erased, TYPE_GENERIC_STRUCT);
    return WirExpr(value=erased, source_type=TYPE_GENERIC_STRUCT);
}

func wir_restore_struct(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirExpr, target_type: Int) -> WirExpr {
    let target_wir: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, target_type);
    if (target_wir == NO_WIR_TYPE) {
        return wir_no_expr();
    }

    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [value.value], [], no_wir_location());
    let uint32_type: WirTypeID = wir_unsigned_int_type(ref program, 32);
    let type_slot: WirValueID = wir_pointer_offset(ref program, state.block, value.value, WIR_ARC_TYPE_OFFSET, wir_pointer_type(ref program, uint32_type));
    let type_tag: WirValueID = wir_load(ref program, state.block, type_slot, "", no_wir_location());
    let expected: WirValueID = wir_const_int(ref program, uint32_type, UInt128(UInt32(target_type)));
    let matches: WirValueID = wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, type_tag, expected, "", no_wir_location());
    wir_guard_runtime(ref state, ref program, matches, "__wl_fail_erased_type");

    let payload: WirValueID = wir_cast(ref program, state.block, value.value, wir_pointer_type(ref program, target_wir), "", no_wir_location());
    let restored: WirValueID = wir_load(ref program, state.block, payload, "", no_wir_location());
    if (wir_take_owned(ref state, value.value)) {
        if (wir_value_needs_drop(ref source, target_type)) {
            wir_emit_ownership_value(ref state, ref types, ref source, ref program, restored, target_type, true);
            wir_track_owned(ref state, restored, target_type);
        }
        wir_release(ref program, state.block, value.value, no_wir_location());
    }
    return WirExpr(value=restored, source_type=target_type);
}

func wir_erase_class(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirExpr) -> WirExpr {
    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let erased: WirValueID = wir_cast(ref program, state.block, value.value, raw_pointer, "", no_wir_location());
    if (wir_take_owned(ref state, value.value)) {
        wir_track_owned(ref state, erased, TYPE_GENERIC_CLASS);
    }
    return WirExpr(value=erased, source_type=TYPE_GENERIC_CLASS);
}

func wir_class_tag_matches(ref state: WirFunctionLowering, ref source: Compiler, ref program: WirModule, tag: WirValueID, target_type: Int) -> WirValueID {
    let uint32_type: WirTypeID = wir_unsigned_int_type(ref program, 32);
    let matches: WirValueID = wir_const_bool(ref program, false);
    let candidate: Int = 100;
    while (candidate < source.type_counter) {
        let info: Optional(StructInfo) = source.struct_id_map.lookup(candidate);
        if ((info is !null) && info.is_class && is_subclass(ref source, candidate, target_type)) {
            let expected: WirValueID = wir_const_int(ref program, uint32_type, UInt128(UInt32(candidate)));
            let equal: WirValueID = wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, tag, expected, "", no_wir_location());
            matches = wir_bool_or(ref program, state.block, matches, equal);
        }
        candidate++;
    }
    return matches;
}

func wir_callable_tag_matches(ref state: WirFunctionLowering, ref source: Compiler, ref program: WirModule, tag: WirValueID, target_type: Int) -> WirValueID {
    let uint32_type: WirTypeID = wir_unsigned_int_type(ref program, 32);
    let matches: WirValueID = wir_const_bool(ref program, false);
    let candidate: Int = 100;
    while (candidate < source.type_counter) {
        if (candidate == target_type || callable_types_compatible(ref source, candidate, target_type)) {
            let expected: WirValueID = wir_const_int(ref program, uint32_type, UInt128(UInt32(candidate)));
            let equal: WirValueID = wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, tag, expected, "", no_wir_location());
            matches = wir_bool_or(ref program, state.block, matches, equal);
        }
        candidate++;
    }
    return matches;
}

func wir_restore_class(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirExpr, target_type: Int) -> WirExpr {
    let target_wir: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, target_type);
    if (target_wir == NO_WIR_TYPE) {
        return wir_no_expr();
    }

    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let null_value: WirValueID = wir_null(ref program, raw_pointer);
    let is_null: WirValueID = wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, value.value, null_value, "", no_wir_location());
    let null_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "class.cast.null."), []);
    let inspect_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "class.cast.inspect."), []);
    let end_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "class.cast.end."), [wir_param("value", target_wir)]);
    wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [is_null], [wir_edge(null_block, []), wir_edge(inspect_block, [])], no_wir_location());

    let null_result: WirValueID = wir_cast(ref program, null_block, null_value, target_wir, "", no_wir_location());
    wir_append(ref program, null_block, WirOpcode.Jump, program.void_type, [], [wir_edge(end_block, [null_result])], no_wir_location());

    state.block = inspect_block;
    let uint32_type: WirTypeID = wir_unsigned_int_type(ref program, 32);
    let type_slot: WirValueID = wir_pointer_offset(ref program, state.block, value.value, WIR_ARC_TYPE_OFFSET, wir_pointer_type(ref program, uint32_type));
    let type_tag: WirValueID = wir_load(ref program, state.block, type_slot, "", no_wir_location());
    let matches: WirValueID = wir_class_tag_matches(ref state, ref source, ref program, type_tag, target_type);
    wir_guard_runtime(ref state, ref program, matches, "__wl_fail_erased_type");
    let restored: WirValueID = wir_cast(ref program, state.block, value.value, target_wir, "", no_wir_location());
    wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(end_block, [restored])], no_wir_location());

    state.block = end_block;
    let result: WirValueID = program.arena.blocks[wir_id_index(UInt32(end_block))].parameters[0];
    if (wir_take_owned(ref state, value.value)) {
        wir_track_owned(ref state, result, target_type);
    }
    return WirExpr(value=result, source_type=target_type);
}

func wir_callable_drop_name(source_type: Int) -> String {
    return "__wl_drop.callable." + source_type;
}

func wir_callable_drop_function(ref types: WirTypeMap, ref program: WirModule, source_type: Int) -> WirFuncID {
    let name: String = wir_callable_drop_name(source_type);
    let function_id: WirFuncID = wir_find_function(program, name);
    if (function_id != NO_WIR_FUNC) { return function_id; }

    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    function_id = wir_add_function(ref program, name, [wir_param("callable", raw_pointer)], program.void_type, false, WirLinkage.Internal, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let context_slot: WirValueID = wir_pointer_offset(ref program, entry, function.parameters[0], program.pointer_bits / 8, wir_pointer_type(ref program, raw_pointer));
    let context: WirValueID = wir_load(ref program, entry, context_slot, "context", no_wir_location());
    wir_release(ref program, entry, context, no_wir_location());
    wir_return(ref program, entry, NO_WIR_VALUE, no_wir_location());
    return function_id;
}

func wir_alloc_callable(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    source_type: Int,
    code: WirValueID,
    context: WirValueID
) -> WirExpr {
    let allocator: Optional(FuncInfo) = wir_compiler_link_function(ref source, "memory_alloc");
    if (!(allocator is !null)) {
        state.errors.append("Function values require the memory_alloc compiler link");
        return wir_no_expr();
    }
    let allocator_id: WirFuncID = wir_find_function(program, allocator.name);
    if (allocator_id == NO_WIR_FUNC) {
        allocator_id = wir_lower_function_decl(ref types, ref source, ref program, allocator);
    }
    if (allocator_id == NO_WIR_FUNC) {
        return wir_no_expr();
    }

    let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let total_size: UInt64 = UInt64(WIR_OBJECT_HEADER_SIZE + (program.pointer_bits / 8) * 2);
    let raw: WirValueID = wir_call(
        ref program,
        state.block,
        wir_function_value(ref program, allocator_id),
        [wir_const_int(ref program, size_type, UInt128(total_size))],
        "",
        no_wir_location()
    );
    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [raw], [], no_wir_location());

    let drop_id: WirFuncID = wir_callable_drop_function(ref types, ref program, source_type);
    let drop_address: WirValueID = wir_const_address(ref program, raw_pointer, wir_function_value(ref program, drop_id), 0L);
    let drop_slot: WirValueID = wir_cast(ref program, state.block, raw, wir_pointer_type(ref program, raw_pointer), "", no_wir_location());
    wir_store(ref program, state.block, drop_address, drop_slot, no_wir_location());

    let uint32_type: WirTypeID = wir_unsigned_int_type(ref program, 32);
    let refcount_slot: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE + WIR_ARC_REFCOUNT_OFFSET, wir_pointer_type(ref program, uint32_type));
    let type_slot: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE + WIR_ARC_TYPE_OFFSET, wir_pointer_type(ref program, uint32_type));
    wir_store(ref program, state.block, wir_const_int(ref program, uint32_type, UInt128(1U)), refcount_slot, no_wir_location());
    wir_store(ref program, state.block, wir_const_int(ref program, uint32_type, UInt128(UInt32(source_type))), type_slot, no_wir_location());

    let callable: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE, raw_pointer);
    let code_slot: WirValueID = wir_cast(ref program, state.block, callable, wir_pointer_type(ref program, raw_pointer), "", no_wir_location());
    let context_slot: WirValueID = wir_pointer_offset(ref program, state.block, callable, program.pointer_bits / 8, wir_pointer_type(ref program, raw_pointer));
    wir_store(ref program, state.block, code, code_slot, no_wir_location());
    wir_store(ref program, state.block, context, context_slot, no_wir_location());
    wir_track_owned(ref state, callable, source_type);
    return WirExpr(value=callable, source_type=source_type);
}

func wir_lower_function_value(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, info: FuncInfo) -> WirExpr {
    if (info.is_varargs) {
        throw_type_error(no_position(), "A C variadic function cannot be used as a White Language Function value.");
        return wir_no_expr();
    }
    let function_id: WirFuncID = wir_find_function(program, info.name);
    if (function_id == NO_WIR_FUNC) {
        function_id = wir_lower_function_decl(ref types, ref source, ref program, info);
    }
    if (function_id == NO_WIR_FUNC) {
        return wir_no_expr();
    }
    let source_type: Int = get_func_type_id(ref source, info.arg_types, info.ret_type, info.variadic_param, callable_arg_names(info, 0));
    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let code: WirValueID = wir_const_address(ref program, raw_pointer, wir_function_value(ref program, function_id), 0L);
    return wir_alloc_callable(ref state, ref types, ref source, ref program, source_type, code, wir_null(ref program, raw_pointer));
}

func wir_method_type(ref source: Compiler, info: FuncInfo) -> Int {
    let arguments: Vector(Struct) = [];
    let i: Int = 1;
    while (info.arg_types is !null && i < info.arg_types.length()) {
        arguments.append(info.arg_types[i]);
        i++;
    }
    return get_method_type_id(ref source, arguments, info.ret_type, info.variadic_param, callable_arg_names(info, 1));
}

func wir_capture_method_receiver(ref state: WirFunctionLowering, ref program: WirModule, receiver: WirExpr, context: WirValueID) -> Void {
    if (!wir_take_owned(ref state, receiver.value)) {
        wir_retain(ref program, state.block, context, no_wir_location());
    }
}

func wir_bind_class_method(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    access: FieldAccessNode,
    owner: StructInfo
) -> WirMemberCall {
    let slot: Int = 0;
    let target: FuncInfo = FuncInfo(name="", base_name="", ret_type=0, arg_types=[], arg_names=[], is_varargs=false, ann_flags=0, compiler_link_name="", abi_name="", mutates_self=false, variadic_param=0, default_args=[], ref_body=NodeID(0U), ref_context=null, ref_bindings=null);
    while (owner.vtable is !null && slot < owner.vtable.length()) {
        let candidate: FuncInfo = owner.vtable[slot];
        if (candidate.base_name == access.field_name) {
            target = candidate;
            break;
        }
        slot++;
    }
    if (!has_func(target)) {
        return WirMemberCall(handled=false, value=wir_no_expr());
    }
    if (wir_lvalue_const(ref state, ref source, access.obj)) {
        throw_type_error(access.pos, "Cannot bind a method through const value");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }

    queue_generic_class_method(ref source, owner, target.base_name);
    let receiver: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, access.obj);
    if (receiver.value == NO_WIR_VALUE) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [receiver.value], [], no_wir_location());

    let table_slot: WirValueID = wir_field_address(ref program, state.block, receiver.value, 0, "", no_wir_location());
    let table: WirValueID = wir_load(ref program, state.block, table_slot, "vtable", no_wir_location());
    let slot_value: WirValueID = wir_const_int(ref program, wir_unsigned_int_type(ref program, program.pointer_bits), UInt128(UIntSize(slot)));
    let method_slot: WirValueID = wir_index_address(ref program, state.block, table, slot_value, "", no_wir_location());
    let code: WirValueID = wir_load(ref program, state.block, method_slot, "method", no_wir_location());
    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let context: WirValueID = wir_cast(ref program, state.block, receiver.value, raw_pointer, "self", no_wir_location());
    let method_type: Int = wir_method_type(ref source, target);
    let callable: WirExpr = wir_alloc_callable(ref state, ref types, ref source, ref program, method_type, code, context);
    if (callable.value == NO_WIR_VALUE) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    wir_capture_method_receiver(ref state, ref program, receiver, context);
    return WirMemberCall(handled=true, value=callable);
}

func wir_bind_interface_method(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    access: FieldAccessNode,
    owner: StructInfo
) -> WirMemberCall {
    let slot: Int = 0;
    while (owner.vtable is !null && slot < owner.vtable.length()) {
        let candidate: MethodDefNode = owner.vtable[slot];
        if (candidate.name_tok.value == access.field_name) {
            break;
        }
        slot++;
    }
    if (owner.vtable is null || slot >= owner.vtable.length()) {
        return WirMemberCall(handled=false, value=wir_no_expr());
    }
    if (wir_lvalue_const(ref state, ref source, access.obj)) {
        throw_type_error(access.pos, "Cannot bind a method through const value");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }

    let method_node: MethodDefNode = owner.vtable[slot];
    let arguments: Vector(Struct) = [];
    let i: Int = 0;
    while (method_node.params is !null && i < method_node.params.length()) {
        let parameter: ParamNode = method_node.params[i];
        arguments.append(TypeListNode(type=interface_method_type(ref source, owner, parameter.type_tok), pass_mode=parameter.pass_mode));
        i++;
    }
    let result_type: Int = interface_method_type(ref source, owner, method_node.return_type);
    let method_type: Int = get_method_type_id(ref source, arguments, result_type, 0, []);

    let receiver: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, access.obj);
    if (receiver.value == NO_WIR_VALUE) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    let object: WirValueID = wir_field(ref program, state.block, receiver.value, 0, "object", no_wir_location());
    let table: WirValueID = wir_field(ref program, state.block, receiver.value, 1, "itable", no_wir_location());
    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [object], [], no_wir_location());
    let slot_value: WirValueID = wir_const_int(ref program, wir_unsigned_int_type(ref program, program.pointer_bits), UInt128(UIntSize(slot)));
    let method_slot: WirValueID = wir_index_address(ref program, state.block, table, slot_value, "", no_wir_location());
    let code: WirValueID = wir_load(ref program, state.block, method_slot, "method", no_wir_location());
    let callable: WirExpr = wir_alloc_callable(ref state, ref types, ref source, ref program, method_type, code, object);
    if (callable.value == NO_WIR_VALUE) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    wir_capture_method_receiver(ref state, ref program, receiver, object);
    return WirMemberCall(handled=true, value=callable);
}

func wir_lower_bound_method(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, access: FieldAccessNode) -> WirMemberCall {
    let owner_type: Int = get_repr_type(ref source, wir_argument_type(ref state, ref source, access.obj));
    let owner: Optional(StructInfo) = null;
    owner = source.struct_id_map.lookup(owner_type);
    if (!(owner is !null)) {
        return WirMemberCall(handled=false, value=wir_no_expr());
    }
    if (owner.is_interface) {
        return wir_bind_interface_method(ref state, ref types, ref source, ref program, access, owner);
    }
    if (owner.is_class) {
        return wir_bind_class_method(ref state, ref types, ref source, ref program, access, owner);
    }
    return WirMemberCall(handled=false, value=wir_no_expr());
}

func wir_lower_generic_method_value(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    generic: GenericTypeNode
) -> WirMemberCall {
    if (!has_node(generic.base_type) || node_tag(generic.base_type) != NODE_FIELD_ACCESS) {
        return WirMemberCall(handled=false, value=wir_no_expr());
    }
    let access: FieldAccessNode = get_field_access_node(ref source.arena, generic.base_type);
    let owner_type: Int = get_repr_type(ref source, wir_argument_type(ref state, ref source, access.obj));
    let owner: Optional(StructInfo) = null;
    owner = source.struct_id_map.lookup(owner_type);
    if (!(owner is !null) || !owner.is_class) {
        state.errors.append("Generic methods can only be bound from class values");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }

    let template: Optional(GenericTemplate) = null;
    template = source.generic_methods.lookup(owner.name + "_" + access.field_name);
    if (!(template is !null)) {
        return WirMemberCall(handled=false, value=wir_no_expr());
    }
    let type_arguments: Optional(Vector(Struct)) = resolve_generic_method_args(ref source, template, generic.type_args, [], generic.pos);
    if (type_arguments is null) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    let target: Optional(FuncInfo) = register_generic_method(ref source, template, owner, type_arguments, generic.pos);
    if (!(target is !null)) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    if (wir_lvalue_const(ref state, ref source, access.obj) && target.mutates_self) {
        throw_type_error(access.pos, "Cannot bind a method through const value");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }

    let function_id: WirFuncID = wir_find_function(program, target.name);
    if (function_id == NO_WIR_FUNC) {
        function_id = wir_lower_function_decl(ref types, ref source, ref program, target);
    }
    if (function_id == NO_WIR_FUNC) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    let receiver: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, access.obj);
    if (receiver.value == NO_WIR_VALUE) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [receiver.value], [], no_wir_location());
    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let code: WirValueID = wir_const_address(ref program, raw_pointer, wir_function_value(ref program, function_id), 0L);
    let context: WirValueID = wir_cast(ref program, state.block, receiver.value, raw_pointer, "self", no_wir_location());
    let callable: WirExpr = wir_alloc_callable(ref state, ref types, ref source, ref program, wir_method_type(ref source, target), code, context);
    if (callable.value == NO_WIR_VALUE) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    wir_capture_method_receiver(ref state, ref program, receiver, context);
    return WirMemberCall(handled=true, value=callable);
}

func wir_call_callable(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    callable: WirValueID,
    source_type: Int,
    signature: SymbolInfo,
    arguments: Vector(WirValueID)
) -> WirValueID {
    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [callable], [], no_wir_location());

    let code_slot: WirValueID = wir_cast(ref program, state.block, callable, wir_pointer_type(ref program, raw_pointer), "", no_wir_location());
    let context_slot: WirValueID = wir_pointer_offset(ref program, state.block, callable, program.pointer_bits / 8, wir_pointer_type(ref program, raw_pointer));
    let code: WirValueID = wir_load(ref program, state.block, code_slot, "code", no_wir_location());
    let context: WirValueID = wir_load(ref program, state.block, context_slot, "context", no_wir_location());
    let is_plain: WirValueID = wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, context, wir_null(ref program, raw_pointer), "plain", no_wir_location());

    let plain_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "call.plain."), []);
    let context_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "call.context."), []);
    let result_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, signature.type);
    if (result_type == NO_WIR_TYPE) { return NO_WIR_VALUE; }
    let merge_parameters: Vector(WirParam) = [];
    if (result_type != program.void_type) {
        merge_parameters.append(wir_param("result", result_type));
    }
    let merge_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "call.end."), merge_parameters);
    wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [is_plain], [wir_edge(plain_block, []), wir_edge(context_block, [])], no_wir_location());

    let plain_signature: WirTypeID = wir_callable_signature(ref types, ref source, ref program, source_type, signature);
    let plain_result: WirValueID = wir_call_typed(ref program, plain_block, code, plain_signature, arguments, "", no_wir_location());
    let plain_edge: Vector(WirValueID) = [];
    if (plain_result != NO_WIR_VALUE) { plain_edge.append(plain_result); }
    wir_append(ref program, plain_block, WirOpcode.Jump, program.void_type, [], [wir_edge(merge_block, plain_edge)], no_wir_location());

    let context_arguments: Vector(WirValueID) = [context];
    let i: Int = 0;
    while (i < arguments.length()) {
        context_arguments.append(arguments[i]);
        i++;
    }
    let context_signature: WirTypeID = wir_callable_signature(ref types, ref source, ref program, source_type, signature, true);
    let context_result: WirValueID = wir_call_typed(ref program, context_block, code, context_signature, context_arguments, "", no_wir_location());
    let context_edge: Vector(WirValueID) = [];
    if (context_result != NO_WIR_VALUE) { context_edge.append(context_result); }
    wir_append(ref program, context_block, WirOpcode.Jump, program.void_type, [], [wir_edge(merge_block, context_edge)], no_wir_location());

    state.block = merge_block;
    if (result_type == program.void_type) { return NO_WIR_VALUE; }
    return program.arena.blocks[wir_id_index(UInt32(merge_block))].parameters[0];
}

func wir_bind_closure_self(ref state: WirFunctionLowering, ref types: WirTypeMap, ref program: WirModule, name: String, source_type: Int, environment: WirValueID) -> Void {
    if (name.length() == 0) {
        return;
    }
    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let address: WirValueID = wir_stack_alloc(ref program, state.entry, raw_pointer, name + ".addr", no_wir_location());
    wir_store(ref program, state.block, environment, address, no_wir_location());
    state.bindings.append(WirBinding(name=name, source_type=source_type, address=address, is_const=true, owns_value=false, pending_init=false, is_const_access=false, is_reference=false));
}

func wir_bind_closure_captures(ref state: WirFunctionLowering, ref program: WirModule, environment: WirValueID, captures: Vector(WirBinding)) -> Void {
    let i: Int = 0;
    while (i < captures.length()) {
        let capture: WirBinding = captures[i];
        let address: WirValueID = wir_field_address(ref program, state.block, environment, i + 2, capture.name + ".capture", no_wir_location());
        state.bindings.append(WirBinding(name=capture.name, source_type=capture.source_type, address=address, is_const=capture.is_const, owns_value=false, pending_init=false, is_const_access=false, is_reference=false));
        i++;
    }
}

func wir_bind_closure_parameters(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    node: FunctionDefNode,
    function: WirFunction,
    parameter_types: Vector(Int)
) -> Void {
    let i: Int = 0;
    while (node.params is !null && i < node.params.length()) {
        let source_parameter: Int = parameter_types[i];
        let parameter: WirValueID = function.parameters[i + 1];
        let parameter_node: ParamNode = node.params[i];
        if (parameter_node.pass_mode == PARAM_REF) {
            state.bindings.append(WirBinding(name=parameter_node.name_tok.value, source_type=source_parameter, address=parameter, is_const=false, owns_value=false, pending_init=false, is_reference=true, is_const_access=false));
        } else {
            let wir_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_parameter);
            let address: WirValueID = wir_stack_alloc(ref program, state.entry, wir_type, parameter_node.name_tok.value + ".addr", no_wir_location());
            wir_store(ref program, state.entry, parameter, address, no_wir_location());
            let owns_value: Bool = wir_value_needs_drop(ref source, source_parameter);
            if owns_value {
                wir_emit_ownership_value(ref state, ref types, ref source, ref program, parameter, source_parameter, true);
            }
            state.bindings.append(WirBinding(name=parameter_node.name_tok.value, source_type=source_parameter, address=address, is_const=false, owns_value=owns_value, pending_init=false, is_const_access=false, is_reference=false));
        }
        i++;
    }
}

func wir_finish_closure_function(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    name: String,
    result_type: WirTypeID
) -> Void {
    if (!state.terminated) {
        if (result_type == program.void_type) {
            wir_cleanup_temporaries(ref state, ref types, ref source, ref program, 0);
            wir_cleanup_bindings(ref state, ref types, ref source, ref program, 0);
            wir_return(ref program, state.block, NO_WIR_VALUE, no_wir_location());
        } else if (is_fallible_type(ref source, state.return_type) && get_inner_fallible_type(ref source, state.return_type) == TYPE_VOID) {
            let result: WirValueID = wir_success_result(ref state, ref types, ref source, ref program, wir_no_expr());
            if (result == NO_WIR_VALUE) {
                state.errors.append("Failed to build the implicit success result");
            } else {
                wir_cleanup_temporaries(ref state, ref types, ref source, ref program, 0);
                wir_cleanup_bindings(ref state, ref types, ref source, ref program, 0);
                wir_return(ref program, state.block, result, no_wir_location());
            }
        } else {
            state.errors.append("Local function '" + name + "' has no terminating return");
        }
    }
    let i: Int = 0;
    while (i < state.errors.length()) {
        types.errors.append("In local function '" + name + "': " + state.errors[i]);
        i++;
    }
}

func wir_lower_closure_function(
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    node: FunctionDefNode,
    captures: Vector(WirBinding),
    env_type: WirTypeID,
    name: String,
    source_type: Int,
    return_type: Int
) -> WirFuncID {
    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let parameters: Vector(WirParam) = [wir_param("environment", raw_pointer)];
    let parameter_types: Vector(Int) = [];
    let i: Int = 0;
    while (node.params is !null && i < node.params.length()) {
        let parameter: ParamNode = node.params[i];
        let source_parameter: TypeListNode = callable_param(ref source, parameter);
        let wir_type: WirTypeID = wir_lower_parameter_type(ref types, ref source, ref program, source_parameter);
        if (wir_type == NO_WIR_TYPE) { return NO_WIR_FUNC; }
        parameter_types.append(source_parameter.type);
        parameters.append(wir_param(parameter.name_tok.value, wir_type));
        i++;
    }
    let result_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, return_type);
    if (result_type == NO_WIR_TYPE) { return NO_WIR_FUNC; }

    let function_id: WirFuncID = wir_add_function(ref program, name, parameters, result_type, false, WirLinkage.Internal, WirABI.White);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let state: WirFunctionLowering = WirFunctionLowering(
        function=function_id,
        return_type=return_type,
        entry=entry,
        block=entry,
        bindings=[],
        loops=[],
        error_targets=[],
        owned_values=[],
        errors=[],
        terminated=false,
        next_block=0,
        binding_indices=null,
        indexed_bindings=0,
        reference_checked=false
    );
    let environment: WirValueID = wir_cast(ref program, entry, function.parameters[0], wir_pointer_type(ref program, env_type), "environment", no_wir_location());
    wir_bind_closure_self(ref state, ref types, ref program, node.name_tok.value, source_type, function.parameters[0]);
    wir_bind_closure_captures(ref state, ref program, environment, captures);
    wir_bind_closure_parameters(ref state, ref types, ref source, ref program, node, function, parameter_types);
    wir_lower_block(ref state, ref types, ref source, ref program, node.body);
    wir_finish_closure_function(ref state, ref types, ref source, ref program, node.name_tok.value, result_type);
    return function_id;
}

func wir_lower_local_closure(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: FunctionDefNode) -> WirExpr {
    let found_captures = wir_closure_captures(ref state, ref source, ref program, node);
    if (found_captures is null) {
        return wir_no_expr();
    }
    let captures: Vector(WirBinding) = found_captures;
    let return_type: Int = resolve_type(ref source, node.ret_type_tok);
    if (return_type == TYPE_AUTO) {
        state.errors.append("Local function '" + node.name_tok.value + "' cannot infer its return type");
        return wir_no_expr();
    }

    let arguments: Vector(Struct) = [];
    let i: Int = 0;
    while (node.params is !null && i < node.params.length()) {
        arguments.append(callable_param(ref source, node.params[i]));
        i++;
    }
    let source_type: Int = get_func_type_id(ref source, arguments, return_type, variadic_param_index(node.params), callable_param_names(node.params));
    let suffix: String = "" + program.arena.functions.length();
    let function_name: String = "lambda." + node.name_tok.value + "." + suffix;
    let env_name: String = "closure.env." + suffix;
    let env_type: WirTypeID = wir_closure_environment_type(ref types, ref source, ref program, captures, env_name);
    if (env_type == NO_WIR_TYPE) {
        return wir_no_expr();
    }

    let function_id: WirFuncID = wir_lower_closure_function(ref types, ref source, ref program, node, captures, env_type, function_name, source_type, return_type);
    if (function_id == NO_WIR_FUNC) {
        return wir_no_expr();
    }
    let drop_id: WirFuncID = wir_closure_environment_drop(ref types, ref source, ref program, env_type, captures, "__wl_drop." + env_name);
    let environment: WirValueID = wir_alloc_closure_environment(ref state, ref types, ref source, ref program, env_type, captures, drop_id, source_type);
    if (environment == NO_WIR_VALUE) {
        return wir_no_expr();
    }
    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let code: WirValueID = wir_const_address(ref program, raw_pointer, wir_function_value(ref program, function_id), 0L);
    wir_initialize_closure_environment(ref state, ref types, ref program, environment, code);
    return wir_alloc_callable(ref state, ref types, ref source, ref program, source_type, code, environment);
}

func wir_lower_local_function(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: FunctionDefNode) -> Void {
    let value: WirExpr = wir_lower_local_closure(ref state, ref types, ref source, ref program, node);
    if (value.value == NO_WIR_VALUE) {
        return;
    }
    let wir_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, value.source_type);
    if (wir_type == NO_WIR_TYPE) {
        return;
    }
    let address: WirValueID = wir_stack_alloc(ref program, state.entry, wir_type, node.name_tok.value + ".addr", no_wir_location());
    wir_move_or_retain(ref state, ref types, ref source, ref program, value);
    wir_store(ref program, state.block, value.value, address, no_wir_location());
    state.bindings.append(WirBinding(name=node.name_tok.value, source_type=value.source_type, address=address, is_const=true, owns_value=true, pending_init=false, is_const_access=false, is_reference=false));
}

func wir_cast_expr(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    value: WirExpr,
    target_type: Int,
    implicit: Bool,
    pos: Position
) -> WirExpr {
    if (value.value == NO_WIR_VALUE || value.source_type == target_type) { return value; }
    let target_union: Bool = is_union_type(ref source, target_type);
    if (target_union) {
        if (!union_accepts_type(ref source, target_type, value.source_type)) {
            throw_type_error(pos, "Type mismatch. Expected " + get_type_name(ref source, target_type) + ", got " + get_type_name(ref source, value.source_type) + ".");
            return wir_no_expr();
        }
        let result: WirValueID = wir_pack_union(ref state, ref types, ref source, ref program, value, target_type);
        if (wir_take_owned(ref state, value.value)) { wir_track_owned(ref state, result, target_type); }
        return WirExpr(value=result, source_type=target_type);
    }
    let source_union: Bool = is_union_type(ref source, value.source_type);
    if (source_union) {
        throw_type_error(pos, "Type mismatch. Expected " + get_type_name(ref source, target_type) + ", got " + get_type_name(ref source, value.source_type) + ".");
        return wir_no_expr();
    }
    let source_info: Optional(StructInfo) = null;
    let target_info: Optional(StructInfo) = null;
    source_info = source.struct_id_map.lookup(get_repr_type(ref source, value.source_type));
    target_info = source.struct_id_map.lookup(get_repr_type(ref source, target_type));
    if ((target_info is !null) && target_info.name == "$Variant") {
        return wir_box_variant(ref state, ref types, ref source, ref program, value, target_info);
    }
    if ((source_info is !null) && source_info.name == "$Variant") {
        return wir_unbox_variant(ref state, ref types, ref source, ref program, value, target_type);
    }
    if (target_type == TYPE_NULL && value.source_type != TYPE_NULLPTR) {
        throw_type_error(pos, "Type mismatch. Expected Null, got " + get_type_name(ref source, value.source_type) + ".");
        return wir_no_expr();
    }
    if ((source_info is !null) && source_info.is_class && (target_info is !null) && target_info.is_interface) {
        return wir_lower_interface_value(ref state, ref types, ref source, ref program, value, target_type);
    }
    if ((source_info is !null) && source_info.is_class && (target_info is !null) && target_info.is_class && is_subclass(ref source, source_info.type_id, target_info.type_id)) {
        let target_wir: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, target_type);
        let casted: WirValueID = wir_cast(ref program, state.block, value.value, target_wir, "", no_wir_location());
        if (wir_take_owned(ref state, value.value)) {
            wir_track_owned(ref state, casted, target_type);
        }
        return WirExpr(value=casted, source_type=target_type);
    }
    if (value.source_type == TYPE_ANY_ERROR && is_integer_type(target_type)) {
        let code: WirValueID = wir_field(ref program, state.block, value.value, 1, "", no_wir_location());
        return wir_cast_expr(ref state, ref types, ref source, ref program, WirExpr(value=code, source_type=TYPE_INT), target_type, implicit, pos);
    }
    if ((source_info is !null) && source_info.is_enum && is_integer_type(target_type)) {
        return wir_cast_expr(ref state, ref types, ref source, ref program, WirExpr(value=value.value, source_type=TYPE_INT), target_type, implicit, pos);
    }
    let erased_callable: Bool = value.source_type == TYPE_GENERIC_FUNCTION || value.source_type == TYPE_GENERIC_METHOD;
    let target_callable: Bool = ((source.func_ret_map.lookup(target_type) is !null)) ||
                                ((source.method_ret_map.lookup(target_type) is !null));
    let source_callable: Bool = ((source.func_ret_map.lookup(value.source_type) is !null)) ||
                                ((source.method_ret_map.lookup(value.source_type) is !null));
    if (implicit && source_callable && target_callable && !callable_types_compatible(ref source, value.source_type, target_type)) {
        state.errors.append("incompatible callable types reached WIR conversion");
        return wir_no_expr();
    }
    if (erased_callable && target_callable) {
        let target_wir: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, target_type);
        let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
        let null_value: WirValueID = wir_null(ref program, raw_pointer);
        let is_null: WirValueID = wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, value.value, null_value, "", no_wir_location());
        let null_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "callable.cast.null."), []);
        let inspect_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "callable.cast.inspect."), []);
        let end_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "callable.cast.end."), [wir_param("value", target_wir)]);
        wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [is_null], [wir_edge(null_block, []), wir_edge(inspect_block, [])], no_wir_location());

        let null_result: WirValueID = wir_cast(ref program, null_block, null_value, target_wir, "", no_wir_location());
        wir_append(ref program, null_block, WirOpcode.Jump, program.void_type, [], [wir_edge(end_block, [null_result])], no_wir_location());

        state.block = inspect_block;
        let uint32_type: WirTypeID = wir_unsigned_int_type(ref program, 32);
        let type_slot: WirValueID = wir_pointer_offset(ref program, state.block, value.value, WIR_ARC_TYPE_OFFSET, wir_pointer_type(ref program, uint32_type));
        let type_tag: WirValueID = wir_load(ref program, state.block, type_slot, "", no_wir_location());
        let matches: WirValueID = wir_callable_tag_matches(ref state, ref source, ref program, type_tag, target_type);
        wir_guard_runtime(ref state, ref program, matches, "__wl_fail_erased_type");
        let restored: WirValueID = wir_cast(ref program, state.block, value.value, target_wir, "", no_wir_location());
        wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(end_block, [restored])], no_wir_location());

        state.block = end_block;
        let result: WirValueID = program.arena.blocks[wir_id_index(UInt32(end_block))].parameters[0];
        if (wir_take_owned(ref state, value.value)) {
            wir_track_owned(ref state, result, target_type);
        }
        return WirExpr(value=result, source_type=target_type);
    }
    if (target_type == TYPE_GENERIC_STRUCT && is_value_struct(ref source, value.source_type)) {
        return wir_erase_struct(ref state, ref types, ref source, ref program, value);
    }
    if (value.source_type == TYPE_GENERIC_STRUCT && is_value_struct(ref source, target_type)) {
        return wir_restore_struct(ref state, ref types, ref source, ref program, value, target_type);
    }
    if (target_type == TYPE_GENERIC_CLASS && (source_info is !null) && source_info.is_class) {
        return wir_erase_class(ref state, ref types, ref source, ref program, value);
    }
    if (value.source_type == TYPE_GENERIC_CLASS && (target_info is !null) && target_info.is_class) {
        return wir_restore_class(ref state, ref types, ref source, ref program, value, target_type);
    }
    let target_array: Optional(ArrayInfo) = null;
    target_array = source.array_info_map.lookup(get_repr_type(ref source, target_type));
    if ((target_array is !null) && target_array.size < 0) {
        let source_type: Int = get_repr_type(ref source, value.source_type);
        let source_array: Optional(ArrayInfo) = null;
        let source_vector: Optional(SymbolInfo) = null;
        source_array = source.array_info_map.lookup(source_type);
        source_vector = source.vector_base_map.lookup(source_type);
        let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
        let zero: WirValueID = wir_const_int(ref program, size_type, UInt128(0U));
        if ((source_array is !null) && source_array.size >= 0 && source_array.base_type == target_array.base_type) {
            let source_wir: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
            let source_slot: WirValueID = wir_stack_alloc(ref program, state.entry, source_wir, "slice.cast.source", no_wir_location());
            wir_store(ref program, state.block, value.value, source_slot, no_wir_location());
            let data: WirValueID = wir_index_address(ref program, state.block, source_slot, zero, "", no_wir_location());
            let length: WirValueID = wir_const_int(ref program, size_type, UInt128(UIntSize(source_array.size)));
            return wir_copy_slice(ref state, ref types, ref source, ref program, target_type, target_array.base_type, data, zero, length);
        }
        if ((source_vector is !null) && source_vector.type == target_array.base_type) {
            wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [value.value], [], no_wir_location());
            let length: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, value.value, 0, "", no_wir_location()), "", no_wir_location());
            let data: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, value.value, 2, "", no_wir_location()), "", no_wir_location());
            let result: WirExpr = wir_copy_slice(ref state, ref types, ref source, ref program, target_type, target_array.base_type, data, zero, length);
            if (wir_take_owned(ref state, value.value)) {
                wir_release(ref program, state.block, value.value, no_wir_location());
            }
            return result;
        }
    }
    let source_wir: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, value.source_type);
    let target_wir: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, target_type);
    if (source_wir == NO_WIR_TYPE || target_wir == NO_WIR_TYPE) {
        return wir_no_expr();
    }
    let source_kind: WirTypeKind = program.arena.types[wir_id_index(UInt32(source_wir))].kind;
    let target_kind: WirTypeKind = program.arena.types[wir_id_index(UInt32(target_wir))].kind;
    let source_integer: Bool = source_kind == WirTypeKind.BoolType || source_kind == WirTypeKind.SignedInt || source_kind == WirTypeKind.UnsignedInt;
    let target_integer: Bool = target_kind == WirTypeKind.BoolType || target_kind == WirTypeKind.SignedInt || target_kind == WirTypeKind.UnsignedInt;
    if (value.source_type == TYPE_NULLPTR) {
        if (!is_pointer_type(ref source, target_type)) {
            throw_type_error(pos, "'nullptr' can only be assigned to explicit pointer types.");
            return wir_no_expr();
        }
        return WirExpr(value=wir_cast(ref program, state.block, value.value, target_wir, "", no_wir_location()), source_type=target_type);
    }
    if (value.source_type == TYPE_NULL) {
        if (is_pointer_type(ref source, target_type)) {
            throw_type_error(pos, "Keyword 'null' cannot be assigned to explicit pointer types. Use 'nullptr'.");
            return wir_no_expr();
        }
        if (!is_nullable_reference_type(ref source, target_type)) {
            throw_type_error(pos, "Type " + get_type_name(ref source, target_type) + " cannot be null.");
            return wir_no_expr();
        }
        if (target_kind == WirTypeKind.Struct) {
            return WirExpr(value=wir_const_zero(ref program, target_wir), source_type=target_type);
        }
        return WirExpr(value=wir_cast(ref program, state.block, value.value, target_wir, "", no_wir_location()), source_type=target_type);
    }
    // Null and nullptr share pointer storage, check their source rules before
    // accepting equal WIR types.
    if (source_wir == target_wir) {
        return WirExpr(value=value.value, source_type=target_type);
    }
    if (source_kind == WirTypeKind.Pointer && target_kind == WirTypeKind.Pointer) {
        let compatible: Bool = is_void_ptr(ref source, value.source_type) ||
                               is_void_ptr(ref source, target_type);
        if (implicit && !compatible) {
            state.errors.append("implicit pointer conversion from " + get_type_name(ref source, value.source_type) + " to " + get_type_name(ref source, target_type) + " reached WIR lowering");
            return wir_no_expr();
        }
        let casted: WirValueID = wir_cast(ref program, state.block, value.value, target_wir, "", no_wir_location());
        if (wir_take_owned(ref state, value.value)) {
            wir_track_owned(ref state, casted, target_type);
        }
        return WirExpr(value=casted, source_type=target_type);
    }
    if (!implicit && source_kind == WirTypeKind.Pointer && target_integer) {
        return WirExpr(value=wir_cast(ref program, state.block, value.value, target_wir, "", no_wir_location()), source_type=target_type);
    }
    if (!implicit && source_integer && target_kind == WirTypeKind.Pointer) {
        return WirExpr(value=wir_cast(ref program, state.block, value.value, target_wir, "", no_wir_location()), source_type=target_type);
    }
    if (source_kind == WirTypeKind.BoolType && target_integer) {
        if implicit {
            throw_type_error(no_position(), "Type mismatch. Expected " + get_type_name(ref source, target_type) + ", got Bool");
            return wir_no_expr();
        }
        return WirExpr(value=wir_cast(ref program, state.block, value.value, target_wir, "", no_wir_location()), source_type=target_type);
    }
    if (source_integer && target_kind == WirTypeKind.BoolType) {
        let one: WirValueID = wir_const_int(ref program, source_wir, UInt128(1U));
        return WirExpr(value=wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, value.value, one, "", no_wir_location()), source_type=target_type);
    }
    let source_repr: Int = get_repr_type(ref source, value.source_type);
    let target_repr: Int = get_repr_type(ref source, target_type);
    if (!wir_source_numeric(source_repr) || !wir_source_numeric(target_repr)) {
        throw_type_error(pos, "Type mismatch. Expected " + get_type_name(ref source, target_type) + ", got " + get_type_name(ref source, value.source_type) + ".");
        return wir_no_expr();
    }
    if (implicit && !wir_implicit_numeric_cast(value.source_type, target_type)) {
        state.errors.append("implicit conversion from " + get_type_name(ref source, value.source_type) + " to " + get_type_name(ref source, target_type) + " reached WIR lowering");
        return wir_no_expr();
    }
    return WirExpr(value=wir_cast(ref program, state.block, value.value, target_wir, "", no_wir_location()), source_type=target_type);
}

func wir_identity_value(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirExpr) -> WirExpr {
    if (value.value == NO_WIR_VALUE) {
        return wir_no_expr();
    }

    let info: Optional(StructInfo) = null;
    info = source.struct_id_map.lookup(get_repr_type(ref source, value.source_type));
    if ((info is !null) && info.is_interface) {
        return WirExpr(value=wir_field(ref program, state.block, value.value, 0, "", no_wir_location()), source_type=TYPE_ANYPTR);
    }

    let value_type: WirTypeID = wir_value_type(ref program, value.value);
    if (program.arena.types[wir_id_index(UInt32(value_type))].kind != WirTypeKind.Pointer) {
        state.errors.append("identity comparison reached WIR lowering with a non-reference operand");
        return wir_no_expr();
    }
    let pointer_type: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let pointer: WirValueID = value.value;
    if (value_type != pointer_type) {
        pointer = wir_cast(ref program, state.block, pointer, pointer_type, "", no_wir_location());
    }
    return WirExpr(value=pointer, source_type=TYPE_ANYPTR);
}

func wir_lvalue_type(ref state: WirFunctionLowering, ref source: Compiler, node: NodeID) -> Int {
    if (!has_node(node)) { return TYPE_POISON; }
    let narrowed = flow_type(ref source, node);
    if (narrowed != 0) { return narrowed; }
    let kind: Int = node_tag(node);
    if (kind == NODE_STRING) { return TYPE_STRING; }
    if (kind == NODE_VAR_ACCESS) {
        let access: VarAccessNode = get_var_access_node(ref source.arena, node);
        let binding: WirBinding = wir_find_binding(ref state, access.name_tok.value)?;
        catch(err) {
            let global: WirSourceGlobal = wir_source_global(ref source, access.name_tok.value);
            if (has_wir_source_global(global)) { return global.source_type; }
            return TYPE_POISON;
        }
        return binding.source_type;
    }
    if (kind == NODE_FIELD_ACCESS) {
        let access: FieldAccessNode = get_field_access_node(ref source.arena, node);
        let object_type: Int = get_repr_type(ref source, wir_lvalue_type(ref state, ref source, access.obj));
        let pointer: Optional(SymbolInfo) = source.ptr_base_map.lookup(object_type);
        if ((pointer is !null)) { object_type = get_repr_type(ref source, pointer.type); }
        let info: Optional(StructInfo) = source.struct_id_map.lookup(object_type);
        if (!(info is !null) || info.is_enum) { return TYPE_POISON; }
        let field: Optional(FieldInfo) = find_field(info, access.field_name);
        if ((field is !null)) { return field.type; }
        return TYPE_POISON;
    }
    if (kind == NODE_INDEX_ACCESS) {
        let access: IndexAccessNode = get_index_access_node(ref source.arena, node);
        let target_type: Int = get_repr_type(ref source, wir_lvalue_type(ref state, ref source, access.target));
        if (target_type == TYPE_STRING) { return TYPE_BYTE; }
        let pointer: Optional(SymbolInfo) = source.ptr_base_map.lookup(target_type);
        if ((pointer is !null)) { return pointer.type; }
        let info: Optional(ArrayInfo) = source.array_info_map.lookup(target_type);
        if ((info is !null)) { return info.base_type; }
        let vector: Optional(SymbolInfo) = source.vector_base_map.lookup(target_type);
        if ((vector is !null)) { return vector.type; }
        let owner: Optional(StructInfo) = source.struct_id_map.lookup(target_type);
        if ((owner is !null) && owner.is_class) {
            let meta_owner: StructInfo = owner;
            let method_index: Int = 0;
            while (meta_owner.vtable is !null && method_index < meta_owner.vtable.length()) {
                let method_info: FuncInfo = meta_owner.vtable[method_index];
                if (method_info.base_name == "get") { return method_info.ret_type; }
                method_index++;
            }
        }
    }
    return TYPE_POISON;
}

func wir_stable_ref_target(ref state: WirFunctionLowering, ref source: Compiler, node: NodeID) -> Bool {
    if (!has_node(node)) { return false; }
    let kind: Int = node_tag(node);
    if (kind == NODE_VAR_ACCESS) {
        let access: VarAccessNode = get_var_access_node(ref source.arena, node);
        let binding: WirBinding = wir_find_binding(ref state, access.name_tok.value)?;
        catch(err) {
            return has_wir_source_global(wir_source_global(ref source, access.name_tok.value));
        }
        return true;
    }
    if (kind == NODE_FIELD_ACCESS) {
        let access: FieldAccessNode = get_field_access_node(ref source.arena, node);
        let owner_type: Int = get_repr_type(ref source, wir_lvalue_type(ref state, ref source, access.obj));
        if (is_pointer_type(ref source, owner_type)) { return false; }
        let owner: Optional(StructInfo) = source.struct_id_map.lookup(owner_type);
        return (owner is !null) && !owner.is_class && wir_stable_ref_target(ref state, ref source, access.obj);
    }
    if (kind == NODE_INDEX_ACCESS) {
        let access: IndexAccessNode = get_index_access_node(ref source.arena, node);
        let target_type: Int = get_repr_type(ref source, wir_lvalue_type(ref state, ref source, access.target));
        let array: Optional(ArrayInfo) = source.array_info_map.lookup(target_type);
        let vector = source.vector_base_map.lookup(target_type);
        let checked = source.ref_targets.contains_key(UInt32(node));
        return (((array is !null) && (array.size >= 0 || checked)) || ((vector is !null) && checked)) &&
               wir_stable_ref_target(ref state, ref source, access.target);
    }
    return false;
}

func wir_enum_value(ref types: WirTypeMap, ref source: Compiler, owner: String, field_name: String) -> Optional(WirEnumValue) {
    let value: Optional(WirEnumValue) = types.enum_values.lookup(owner + "." + field_name);
    if (value is !null) { return value; }

    let mapped: Optional(String) = source.global_type_aliases.lookup(owner);
    if (mapped is null) { return null; }
    return types.enum_values.lookup(mapped + "." + field_name);
}

func wir_enum_member(ref types: WirTypeMap, ref source: Compiler, node_id: NodeID, node: FieldAccessNode) -> Optional(WirEnumValue) {
    if (!has_node(node.obj)) {
        return null;
    }
    let owner: String = format_ast_path(ref source, node.obj);
    if (owner == "<unknown_path>") { return null; }
    let source_name: String = owner + "." + node.field_name;
    let mapped: Optional(String) = source.current_file_global_aliases.lookup(source_name);
    if (mapped is !null) {
        let mapped_value: Optional(WirEnumValue) = types.enum_values.lookup(mapped);
        if (mapped_value is !null) { return mapped_value; }
    }
    let value: Optional(WirEnumValue) = null;
    if (source.current_package_prefix.length() != 0) {
        value = wir_enum_value(ref types, ref source, source.current_package_prefix + owner, node.field_name);
        if (value is !null) { return value; }
    }

    let owner_dot: Int = 0;
    while (owner_dot < owner.length() && owner[owner_dot] != '.') { owner_dot++; }
    if (owner_dot >= owner.length()) {
        value = wir_enum_value(ref types, ref source, owner, node.field_name);
        if (value is !null) { return value; }
    }

    let separator: Int = 0;
    while (separator < owner.length() && owner[separator] != '.') { separator++; }
    if (separator < owner.length()) {
        let root: String = owner.slice(0, separator);
        let prefix: Optional(String) = source.current_file_visible_prefixes.lookup(root);
        if (prefix is !null) {
            let qualified_owner: String = prefix + owner.slice(separator + 1, owner.length());
            value = wir_enum_value(ref types, ref source, qualified_owner, node.field_name);
            if (value is !null) { return value; }
        }
    }

    mapped = source.current_file_type_aliases.lookup(owner);
    if (mapped is !null) {
        value = wir_enum_value(ref types, ref source, mapped, node.field_name);
        if (value is !null) { return value; }
    }
    mapped = source.global_type_aliases.lookup(owner);
    if (mapped is !null) {
        return wir_enum_value(ref types, ref source, mapped, node.field_name);
    }
    let resolved_type: Int = get_expr_type(ref source, node_id);
    let info: Optional(StructInfo) = source.struct_id_map.lookup(get_repr_type(ref source, resolved_type));
    if ((info is !null) && info.is_enum) {
        let field: Optional(FieldInfo) = find_field(info, node.field_name);
        if ((field is !null)) {
            return WirEnumValue(source_type=resolved_type, value=Long(field.offset));
        }
    }
    return null;
}

func wir_lvalue_const(ref state: WirFunctionLowering, ref source: Compiler, node: NodeID) -> Bool {
    if (!has_node(node)) { return false; }
    let kind: Int = node_tag(node);
    if (kind == NODE_VAR_ACCESS) {
        let access: VarAccessNode = get_var_access_node(ref source.arena, node);
        let binding: WirBinding = wir_find_binding(ref state, access.name_tok.value)?;
        catch(err) {
            let global: WirSourceGlobal = wir_source_global(ref source, access.name_tok.value);
            return has_wir_source_global(global) && global.is_const;
        }
        return binding.is_const || binding.is_const_access;
    }
    if (kind == NODE_FIELD_ACCESS) {
        let access: FieldAccessNode = get_field_access_node(ref source.arena, node);
        if (wir_lvalue_const(ref state, ref source, access.obj)) { return true; }
        let object_type: Int = get_repr_type(ref source, wir_lvalue_type(ref state, ref source, access.obj));
        let info: Optional(StructInfo) = source.struct_id_map.lookup(object_type);
        let field: Optional(FieldInfo) = find_field(info, access.field_name);
        return (field is !null) && field.is_const;
    }
    if (kind == NODE_INDEX_ACCESS) {
        return wir_lvalue_const(ref state, ref source, get_index_access_node(ref source.arena, node).target);
    }
    return false;
}

func wir_field_const(ref state: WirFunctionLowering, ref source: Compiler, object: NodeID, name: String) -> Bool {
    if (wir_lvalue_const(ref state, ref source, object)) { return true; }
    let object_type: Int = get_repr_type(ref source, wir_lvalue_type(ref state, ref source, object));
    let info: Optional(StructInfo) = source.struct_id_map.lookup(object_type);
    let field: Optional(FieldInfo) = find_field(info, name);
    return (field is !null) && field.is_const;
}

func wir_addressable_node(ref source: Compiler, node: NodeID) -> Bool {
    while (has_node(node)) {
        let kind: Int = node_tag(node);
        if (kind == NODE_VAR_ACCESS) { return true; }
        if (kind == NODE_FIELD_ACCESS) {
            node = get_field_access_node(ref source.arena, node).obj;
        } else if (kind == NODE_INDEX_ACCESS) {
            node = get_index_access_node(ref source.arena, node).target;
        } else {
            return false;
        }
    }
    return false;
}

func wir_lower_field_lvalue(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, object_node: NodeID, name: String) -> WirExpr {
    let object_type: Int = get_repr_type(ref source, wir_lvalue_type(ref state, ref source, object_node));
    let indirect: Bool = false;
    let pointer: Optional(SymbolInfo) = source.ptr_base_map.lookup(object_type);
    if ((pointer is !null)) {
        object_type = get_repr_type(ref source, pointer.type);
        indirect = true;
    }
    let info: Optional(StructInfo) = source.struct_id_map.lookup(object_type);
    if (!(info is !null) || info.is_interface || info.is_enum) {
        state.errors.append("field '" + name + "' has no addressable owner for source type " + object_type + " in WIR lowering");
        return wir_no_expr();
    }
    let field: Optional(FieldInfo) = find_field(info, name);
    if (!(field is !null)) {
        state.errors.append("field '" + name + "' does not exist on '" + info.name + "' during WIR lowering");
        return wir_no_expr();
    }

    let object: WirExpr = wir_no_expr();
    if (info.is_class || indirect) {
        object = wir_lower_expr(ref state, ref types, ref source, ref program, object_node);
        if (object.value == NO_WIR_VALUE) {
            return wir_no_expr();
        }
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [object.value], [], no_wir_location());
    } else {
        object = wir_lower_lvalue(ref state, ref types, ref source, ref program, object_node);
        if (object.value == NO_WIR_VALUE) {
            return wir_no_expr();
        }
        let member = flow_type(ref source, object_node);
        if (member != 0 && member != TYPE_NULL && is_union_type(ref source, get_repr_type(ref source, object.source_type))) {
            object = WirExpr(value=wir_union_payload(ref state, ref types, ref source, ref program, object.value, member), source_type=member);
        }
    }
    return WirExpr(value=wir_field_address(ref program, state.block, object.value, field.offset, "", no_wir_location()), source_type=field.type);
}

func wir_lower_index_lvalue(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    target_node: NodeID,
    index_node: NodeID
) -> WirExpr {
    let target_type: Int = get_repr_type(ref source, wir_lvalue_type(ref state, ref source, target_node));
    let write_facts: Vector(FlowType) = [];
    let target_array = source.array_info_map.lookup(target_type);
    if ((target_array is !null) && target_array.size >= 0) { write_facts = flow_write_facts(ref source, target_node); }
    let index: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, index_node);
    if (index.value == NO_WIR_VALUE) { return wir_no_expr(); }
    if (!flow_write_valid(ref source, write_facts)) {
        throw_type_error(no_position(), "Optional index assignment loses its null check while evaluating the index.");
        return wir_no_expr();
    }
    if (index.source_type != TYPE_INT) {
        state.errors.append("array index reached WIR lowering with a non-Int type");
        return wir_no_expr();
    }

    let pointer: Optional(SymbolInfo) = source.ptr_base_map.lookup(target_type);
    if ((pointer is !null)) {
        if (pointer.type == TYPE_VOID) {
            state.errors.append("Void pointer reached WIR lowering with an index operation");
            return wir_no_expr();
        }
        let target: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, target_node);
        if (target.value == NO_WIR_VALUE) {
            return wir_no_expr();
        }
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [target.value], [], no_wir_location());
        return WirExpr(value=wir_index_address(ref program, state.block, target.value, index.value, "", no_wir_location()), source_type=pointer.type);
    }

    let info: Optional(ArrayInfo) = source.array_info_map.lookup(target_type);
    if ((info is !null)) {
        if (info.size >= 0) {
            let target: WirExpr = wir_lower_lvalue(ref state, ref types, ref source, ref program, target_node);
            if (target.value == NO_WIR_VALUE) {
                return wir_no_expr();
            }
            let member = flow_type(ref source, target_node);
            if (member != 0 && is_union_type(ref source, target.source_type)) {
                target = WirExpr(value=wir_union_payload(ref state, ref types, ref source, ref program, target.value, member), source_type=member);
            }
            let length: WirValueID = wir_const_int(ref program, wir_lower_source_type(ref types, ref source, ref program, TYPE_INT), UInt128(UInt32(info.size)));
            wir_append(ref program, state.block, WirOpcode.BoundsCheck, program.void_type, [index.value, length], [], no_wir_location());
            return WirExpr(value=wir_index_address(ref program, state.block, target.value, index.value, "", no_wir_location()), source_type=info.base_type);
        }

        let target: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, target_node);
        if (target.value == NO_WIR_VALUE) {
            return wir_no_expr();
        }
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [target.value], [], no_wir_location());
        let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
        let size_index: WirExpr = wir_cast_expr(ref state, ref types, ref source, ref program, index, TYPE_UINTSIZE, false, no_position());
        if (size_index.value == NO_WIR_VALUE) {
            return wir_no_expr();
        }
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

    let vector: Optional(SymbolInfo) = source.vector_base_map.lookup(target_type);
    if ((vector is !null)) {
        let target: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, target_node);
        if (target.value == NO_WIR_VALUE) {
            return wir_no_expr();
        }
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [target.value], [], no_wir_location());
        let size_index: WirExpr = wir_cast_expr(ref state, ref types, ref source, ref program, index, TYPE_UINTSIZE, false, no_position());
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

func wir_lower_index_expr(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, access: IndexAccessNode, preserve_fallible: Bool) -> WirExpr {
    let target_type: Int = get_repr_type(ref source, wir_lvalue_type(ref state, ref source, access.target));
    let owner: Optional(StructInfo) = source.struct_id_map.lookup(target_type);
    if ((owner is !null) && owner.is_class) {
        let meta_owner: StructInfo = owner;
        let has_get: Bool = false;
        let i: Int = 0;
        while (meta_owner.vtable is !null && i < meta_owner.vtable.length()) {
            let candidate: FuncInfo = meta_owner.vtable[i];
            if (candidate.base_name == "get") {
                has_get = true;
                break;
            }
            i++;
        }
        if has_get {
            let callee: NodeID = add_field_access_node(ref source.arena, FieldAccessNode(type=NODE_FIELD_ACCESS, obj=access.target, field_name="get", pos=access.pos));
            let arguments: Vector(ArgNode) = [ArgNode(val=access.index_node, name="", is_spread=false)];
            let call: CallNode = CallNode(type=NODE_CALL, callee=callee, args=arguments, type_args=[], pos=access.pos, preserve_fallible=preserve_fallible);
            let result: WirMemberCall = wir_lower_class_call(ref state, ref types, ref source, ref program, call);
            if (result.handled) { return result.value; }
        }
    }
    if (target_type == TYPE_STRING) {
        let target: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, access.target);
        let index: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, access.index_node);
        if (target.value == NO_WIR_VALUE || index.value == NO_WIR_VALUE) {
            return wir_no_expr();
        }
        if (index.source_type != TYPE_INT) {
            state.errors.append("String index reached WIR lowering with a non-Int type");
            return wir_no_expr();
        }
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [target.value], [], no_wir_location());
        let data: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, target.value, 0, "", no_wir_location()), "", no_wir_location());
        let length: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, target.value, 1, "", no_wir_location()), "", no_wir_location());
        wir_append(ref program, state.block, WirOpcode.BoundsCheck, program.void_type, [index.value, length], [], no_wir_location());
        return WirExpr(value=wir_load(
            ref program,
            state.block,
            wir_index_address(ref program, state.block, data, index.value, "", no_wir_location()),
            "",
            no_wir_location()
        ), source_type=TYPE_BYTE);
    }

    let address: WirExpr = wir_lower_index_lvalue(ref state, ref types, ref source, ref program, access.target, access.index_node);
    if (address.value == NO_WIR_VALUE) {
        return wir_no_expr();
    }
    return WirExpr(value=wir_load(ref program, state.block, address.value, "", no_wir_location()), source_type=address.source_type);
}

func wir_lower_lvalue(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: NodeID) -> WirExpr {
    if (!has_node(node)) {
        state.errors.append("missing lvalue reached WIR lowering");
        return wir_no_expr();
    }

    let kind: Int = node_tag(node);
    if (kind == NODE_VAR_ACCESS) {
        let access: VarAccessNode = get_var_access_node(ref source.arena, node);
        let binding: WirBinding = wir_find_binding(ref state, access.name_tok.value)?;
        catch(err) {
            let global: WirSourceGlobal = wir_source_global(ref source, access.name_tok.value);
            let global_id: WirGlobalID = NO_WIR_GLOBAL;
            if (has_wir_source_global(global)) { global_id = wir_find_global(program, global.name); }
            if (global_id == NO_WIR_GLOBAL) {
                throw_name_error(access.pos, "Undefined variable or function '" + access.name_tok.value + "'.");
                return wir_no_expr();
            }
            return WirExpr(value=wir_global_value(ref program, global_id), source_type=global.source_type);
        }
        return WirExpr(value=binding.address, source_type=binding.source_type);
    }

    if (kind == NODE_FIELD_ACCESS) {
        let access: FieldAccessNode = get_field_access_node(ref source.arena, node);
        let global: WirSourceGlobal = wir_direct_global(ref state, ref source, node);
        if (has_wir_source_global(global)) {
            let global_id: WirGlobalID = wir_find_global(program, global.name);
            if (global_id == NO_WIR_GLOBAL) {
                state.errors.append("global '" + global.name + "' was not declared before WIR lowering");
                return wir_no_expr();
            }
            return WirExpr(value=wir_global_value(ref program, global_id), source_type=global.source_type);
        }
        return wir_lower_field_lvalue(ref state, ref types, ref source, ref program, access.obj, access.field_name);
    }

    if (kind == NODE_INDEX_ACCESS) {
        let access: IndexAccessNode = get_index_access_node(ref source.arena, node);
        return wir_lower_index_lvalue(ref state, ref types, ref source, ref program, access.target, access.index_node);
    }

    state.errors.append("expression is not an addressable WIR value");
    return wir_no_expr();
}

func wir_lower_address(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    node: NodeID,
    expected_type: Int,
    pos: Position
) -> WirExpr {
    if (!has_node(node) || node_tag(node) != NODE_REF) {
        throw_type_error(pos, "Expected a reference argument for " + get_type_name(ref source, expected_type) + "; pass a writable value with 'ref'.");
        return wir_no_expr();
    }
    let reference: RefNode = get_ref_node(ref source.arena, node);
    let kind: Int = node_tag(reference.node);
    flow_expose(ref source, reference.node);
    if (kind != NODE_VAR_ACCESS && kind != NODE_FIELD_ACCESS && kind != NODE_INDEX_ACCESS) {
        throw_invalid_syntax(pos, "Cannot take ref of r-value.");
        return wir_no_expr();
    }
    if (wir_lvalue_const(ref state, ref source, reference.node)) {
        let name: String = expr_root_name(ref source, reference.node);
        throw_type_error(pos, "Cannot modify value through const access '" + name + "'");
        return wir_no_expr();
    }
    let address: WirExpr = wir_lower_lvalue(ref state, ref types, ref source, ref program, reference.node);
    if (address.value != NO_WIR_VALUE && address.source_type != expected_type) {
        throw_type_error(pos, "Reference argument type mismatch. Expected ref " + get_type_name(ref source, expected_type) + ", got " + get_type_name(ref source, address.source_type) + ".");
        return wir_no_expr();
    }
    return address;
}

func wir_struct_constructor(ref source: Compiler, node: NodeID) -> Optional(StructInfo) {
    if (!has_node(node)) {
        return null;
    }
    let kind: Int = node_tag(node);
    if (kind == NODE_GENERIC_TYPE) {
        node = get_generic_type_node(ref source.arena, node).base_type;
        kind = node_tag(node);
    }
    if (kind != NODE_VAR_ACCESS && kind != NODE_FIELD_ACCESS) {
        return null;
    }
    let name: String = format_ast_path(ref source, node);
    let info: Optional(StructInfo) = null;
    if (source.current_package_prefix.length() != 0) {
        info = source.struct_table.lookup(source.current_package_prefix + name);
    }
    if (!(info is !null)) { info = source.struct_table.lookup(name); }
    if (!(info is !null)) {
        let mapped: Optional(String) = source.current_file_type_aliases.lookup(name);
        if (mapped is !null) { info = source.struct_table.lookup(mapped); }
    }
    if (!(info is !null)) {
        let mapped: Optional(String) = source.global_type_aliases.lookup(name);
        if (mapped is !null) { info = source.struct_table.lookup(mapped); }
    }
    if (!(info is !null) && kind == NODE_FIELD_ACCESS) {
        let separator: Int = 0;
        while (separator < name.length() && name[separator] != '.') { separator++; }
        if (separator < name.length()) {
            let root: String = name.slice(0, separator);
            let prefix: Optional(String) = source.current_file_visible_prefixes.lookup(root);
            if (prefix is !null) {
                let qualified: String = prefix + name.slice(separator + 1, name.length());
                info = source.struct_table.lookup(qualified);
                if (!(info is !null)) {
                    let mapped: Optional(String) = source.global_type_aliases.lookup(qualified);
                    if (mapped is !null) { info = source.struct_table.lookup(mapped); }
                }
            }
        }
    }
    return info;
}

func wir_generic_constructor(ref source: Compiler, node: NodeID) -> Optional(GenericTemplate) {
    if (!has_node(node)) {
        return null;
    }
    let kind: Int = node_tag(node);
    if (kind == NODE_GENERIC_TYPE) {
        node = get_generic_type_node(ref source.arena, node).base_type;
        kind = node_tag(node);
    }
    if (kind != NODE_VAR_ACCESS && kind != NODE_FIELD_ACCESS) {
        return null;
    }

    let name: String = format_ast_path(ref source, node);
    let generic: Optional(GenericTemplate) = null;
    if (source.current_package_prefix.length() != 0) {
        generic = source.generic_structs.lookup(source.current_package_prefix + name);
    }
    if (!(generic is !null)) { generic = source.generic_structs.lookup(name); }
    if (!(generic is !null)) {
        let mapped: Optional(String) = source.current_file_type_aliases.lookup(name);
        if (mapped is !null) { generic = source.generic_structs.lookup(mapped); }
    }
    if (!(generic is !null)) {
        let mapped: Optional(String) = source.global_type_aliases.lookup(name);
        if (mapped is !null) { generic = source.generic_structs.lookup(mapped); }
    }
    if (!(generic is !null) && kind == NODE_FIELD_ACCESS) {
        let separator: Int = 0;
        while (separator < name.length() && name[separator] != '.') { separator++; }
        if (separator < name.length()) {
            let root: String = name.slice(0, separator);
            let prefix: Optional(String) = source.current_file_visible_prefixes.lookup(root);
            if (prefix is !null) {
                let qualified: String = prefix + name.slice(separator + 1, name.length());
                generic = source.generic_structs.lookup(qualified);
                if (!(generic is !null)) {
                    let mapped: Optional(String) = source.global_type_aliases.lookup(qualified);
                    if (mapped is !null) { generic = source.generic_structs.lookup(mapped); }
                }
            }
        }
    }
    return generic;
}

func wir_lower_array_literal(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: NodeID, expected_type: Int) -> WirExpr {
    let source_type: Int = get_repr_type(ref source, expected_type);
    let vector: Optional(SymbolInfo) = null;
    vector = source.vector_base_map.lookup(source_type);
    if ((vector is !null)) {
        return wir_lower_vector_literal(ref state, ref types, ref source, ref program, node, source_type, vector.type);
    }
    let info: Optional(ArrayInfo) = source.array_info_map.lookup(source_type);
    if (!(info is !null) || info.size < 0) {
        state.errors.append("array literal reached WIR lowering without a fixed-array target type");
        return wir_no_expr();
    }
    let meta_info: ArrayInfo = info;

    let literal: VectorLitNode = get_vector_lit_node(ref source.arena, node);
    if (literal.elements.length() > meta_info.size) {
        state.errors.append("array literal has more elements than its target type in WIR lowering");
        return wir_no_expr();
    }
    let elements: Vector(WirValueID) = [];
    let i: Int = 0;
    while (i < literal.elements.length()) {
        let argument: ArgNode = literal.elements[i];
        if ((argument.name.length() != 0) || argument.is_spread) {
            state.errors.append("array literal contains a named or spread element in WIR lowering");
            return wir_no_expr();
        }
        let element: WirExpr = wir_lower_expected_expr(ref state, ref types, ref source, ref program, argument.val, meta_info.base_type);
        if (element.value == NO_WIR_VALUE) {
            return wir_no_expr();
        }
        element = wir_cast_expr(ref state, ref types, ref source, ref program, element, meta_info.base_type, true, no_position());
        if (element.value == NO_WIR_VALUE) {
            return wir_no_expr();
        }
        wir_move_or_retain(ref state, ref types, ref source, ref program, element);
        elements.append(element.value);
        i++;
    }
    let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, expected_type);
    let result: WirValueID = wir_array_value(ref program, state.block, type_id, elements, "", no_wir_location());
    if (wir_value_needs_drop(ref source, expected_type)) {
        wir_track_owned(ref state, result, expected_type);
    }
    return WirExpr(value=result, source_type=expected_type);
}

func wir_lower_struct_default(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, info: StructInfo, field: FieldInfo, pos: Position) -> WirExpr {
// defaults resolve in the declaring module, with the concrete generic bindings
    let locals = state.bindings;
    let indices = state.binding_indices;
    let indexed = state.indexed_bindings;
    let scope = source.symbol_table;
    let scopes = source.scope_stack;
    let bindings = source.generic_bindings;
    let saved: Optional(GenericTemplate) = null;
    let context = source.struct_contexts.lookup(info.type_id);
    if (context is !null) {
        let instance_bindings: Dict(String, SymbolInfo) = Dict();
        let found = source.generic_instance_bindings.lookup("" + info.type_id);
        if (found is !null) { instance_bindings = found; }
        saved = use_generic_context(ref source, context, instance_bindings);
    }
    source.symbol_table = Scope(table=Dict(), parent=-1, gc_vars=[], depth=0);
    source.scope_stack = [];
    let hidden: Vector(WirBinding) = [];
    let local_idx = 0;
    while (local_idx < locals.length()) {
        let local = locals[local_idx];
        local.name = "";
        hidden.append(local);
        local_idx++;
    }
    state.bindings = hidden;
    state.binding_indices = null;
    state.indexed_bindings = 0;
    let value = wir_lower_expected_expr(ref state, ref types, ref source, ref program, field.default_val, field.type);
    if (value.value != NO_WIR_VALUE) {
        value = wir_cast_expr(ref state, ref types, ref source, ref program, value, field.type, true, pos);
    }
    state.bindings = locals;
    state.binding_indices = indices;
    state.indexed_bindings = indexed;
    source.symbol_table = scope;
    source.scope_stack = scopes;
    if (saved is !null) { restore_generic_context(ref source, saved, bindings); }
    return value;
}

func wir_lower_struct_constructor(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    call: CallNode,
    info: StructInfo
) -> WirExpr {
    if (info.is_class || info.is_interface || info.is_enum) {
        return wir_no_expr();
    }
    if (!check_struct_init(ref source, info, call)) {
        return wir_no_expr();
    }
    let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, info.type_id);
    if (type_id == NO_WIR_TYPE) {
        return wir_no_expr();
    }

    let object_slot: WirValueID = NO_WIR_VALUE;
    let temporary_start = state.bindings.length();
    if (has_node(info.init_body)) {
        object_slot = wir_stack_alloc(ref program, state.entry, type_id, "struct.init", no_wir_location());
        wir_store(ref program, state.block, wir_const_zero(ref program, type_id), object_slot, no_wir_location());
        // an unfinished object owns the fields already stored, error edges must drop them
        state.bindings.append(WirBinding(name="", source_type=info.type_id, address=object_slot, is_const=false, owns_value=true, pending_init=false, is_const_access=false, is_reference=false));
        let binding_count: Int = state.bindings.length();
        let default_idx = 0;
        while (default_idx < info.fields.length()) {
            let field: FieldInfo = info.fields[default_idx];
            if (has_node(field.default_val) && !struct_arg_supplied(call, field)) {
                let value = wir_lower_struct_default(ref state, ref types, ref source, ref program, info, field, call.pos);
                if (value.value == NO_WIR_VALUE) { return wir_no_expr(); }
                wir_move_or_retain(ref state, ref types, ref source, ref program, value);
                let slot = wir_field_address(ref program, state.block, object_slot, field.offset, "", no_wir_location());
                wir_store(ref program, state.block, value.value, slot, no_wir_location());
            }
            default_idx++;
        }
        state.bindings.append(WirBinding(name="this", source_type=info.type_id, address=object_slot, is_const=false, owns_value=false, pending_init=false, is_const_access=false, is_reference=false));
        wir_lower_block(ref state, ref types, ref source, ref program, info.init_body);
        wir_restore_bindings(ref state, binding_count);
        if (state.terminated) {
            state.errors.append("struct initializer terminated control flow during WIR lowering");
            return wir_no_expr();
        }
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
        let field: FieldInfo = info.fields[i];
        let value = NO_WIR_VALUE;
        if (object_slot == NO_WIR_VALUE && has_node(field.default_val) && !struct_arg_supplied(call, field)) {
            let evaluated = wir_lower_struct_default(ref state, ref types, ref source, ref program, info, field, call.pos);
            if (evaluated.value == NO_WIR_VALUE) { return wir_no_expr(); }
            wir_move_or_retain(ref state, ref types, ref source, ref program, evaluated);
            if (wir_value_needs_drop(ref source, field.type)) {
                wir_track_owned(ref state, evaluated.value, field.type);
            }
            value = evaluated.value;
        }
        values.append(value);
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
            let field: Optional(FieldInfo) = find_field(info, argument.name);
            if (!(field is !null)) {
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
        if (value.value == NO_WIR_VALUE) {
            return wir_no_expr();
        }
        value = wir_cast_expr(ref state, ref types, ref source, ref program, value, field.type, true, no_position());
        if (value.value == NO_WIR_VALUE) { return wir_no_expr(); }
        wir_move_or_retain(ref state, ref types, ref source, ref program, value);
        if (wir_value_needs_drop(ref source, field.type)) {
            wir_track_owned(ref state, value.value, field.type);
        }
        values[field_index] = value.value;
        assigned[field_index] = true;
        i++;
    }

    let result: WirValueID = NO_WIR_VALUE;
    if (object_slot != NO_WIR_VALUE) {
        i = 0;
        while (i < field_count) {
            if (assigned[i]) {
                let field: FieldInfo = info.fields[i];
                let address: WirValueID = wir_field_address(ref program, state.block, object_slot, field.offset, "", no_wir_location());
                if (wir_value_needs_drop(ref source, field.type)) {
                    wir_emit_ownership_slot(ref state, ref types, ref source, ref program, address, field.type, false);
                }
                wir_store(ref program, state.block, values[i], address, no_wir_location());
                wir_take_owned(ref state, values[i]);
            }
            i++;
        }
        result = wir_load(ref program, state.block, object_slot, "", no_wir_location());
    } else {
        let operands: Vector(WirValueID) = [];
        i = 0;
        while (i < field_count) {
            operands.append(values[i]);
            wir_take_owned(ref state, values[i]);
            i++;
        }
        result = wir_struct_value(ref program, state.block, type_id, operands, "", no_wir_location());
    }
    wir_restore_bindings(ref state, temporary_start);
    if (wir_value_needs_drop(ref source, info.type_id)) {
        wir_track_owned(ref state, result, info.type_id);
    }
    return WirExpr(value=result, source_type=info.type_id);
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
    let state: WirFunctionLowering = WirFunctionLowering(
        function=function_id,
        return_type=TYPE_VOID,
        entry=entry,
        block=entry,
        bindings=[],
        loops=[],
        error_targets=[],
        owned_values=[],
        errors=[],
        terminated=false,
        next_block=0,
        binding_indices=null,
        indexed_bindings=0,
        reference_checked=false
    );
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
        wir_emit_ownership_value(ref state, ref types, ref source, ref program, element, element_type, false);
        let one: WirValueID = wir_const_int(ref program, size_type, UInt128(1U));
        let next: WirValueID = wir_binary(ref program, state.block, WirOpcode.Add, size_type, index, one, "", no_wir_location());
        wir_store(ref program, state.block, next, index_slot, no_wir_location());
        wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(condition, [])], no_wir_location());
        state.block = finish;
    }

    let deallocator: Optional(FuncInfo) = wir_compiler_link_function(ref source, "memory_free");
    if (!(deallocator is !null)) {
        types.errors.append("Vector drop glue requires the memory_free compiler link");
    } else {
        let deallocator_id: WirFuncID = wir_find_function(program, deallocator.name);
        if (deallocator_id == NO_WIR_FUNC) {
            deallocator_id = wir_lower_function_decl(ref types, ref source, ref program, deallocator);
        }
        if (deallocator_id != NO_WIR_FUNC) {
            let raw_data: WirValueID = wir_cast(ref program, state.block, data, raw_pointer, "", no_wir_location());
            wir_call(ref program, state.block, wir_function_value(ref program, deallocator_id), [raw_data], "", no_wir_location());
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

func wir_lower_vector_literal(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    node: NodeID,
    source_type: Int,
    element_type: Int
) -> WirExpr {
    let literal: VectorLitNode = get_vector_lit_node(ref source.arena, node);
    let vector_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
    if (vector_type == NO_WIR_TYPE) {
        return wir_no_expr();
    }
    let pointer: WirType = program.arena.types[wir_id_index(UInt32(vector_type))];
    if (pointer.kind != WirTypeKind.Pointer) {
        state.errors.append("Vector target has no pointer representation in WIR lowering");
        return wir_no_expr();
    }
    let payload: WirTypeLayout = wir_lowering_layout(ref types, program, pointer.element);
    let element_wir: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, element_type);
    let element_layout: WirTypeLayout = wir_lowering_layout(ref types, program, element_wir);
    if (!payload.valid || !element_layout.valid || element_layout.size == 0UL) {
        state.errors.append("Vector layout is unavailable during WIR lowering");
        return wir_no_expr();
    }

    let allocator: Optional(FuncInfo) = wir_compiler_link_function(ref source, "memory_alloc");
    if (!(allocator is !null)) {
        state.errors.append("Vector construction requires the memory_alloc compiler link");
        return wir_no_expr();
    }
    let meta_allocator: FuncInfo = allocator;
    let allocator_id: WirFuncID = wir_find_function(program, meta_allocator.name);
    if (allocator_id == NO_WIR_FUNC) {
        allocator_id = wir_lower_function_decl(ref types, ref source, ref program, meta_allocator);
    }
    if (allocator_id == NO_WIR_FUNC) { return wir_no_expr(); }

    let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
    let object_size: UInt64 = payload.size + UInt64(WIR_OBJECT_HEADER_SIZE);
    let raw: WirValueID = wir_call(
        ref program,
        state.block,
        wir_function_value(ref program, allocator_id),
        [wir_const_int(ref program, size_type, UInt128(object_size))],
        "",
        no_wir_location()
    );
    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [raw], [], no_wir_location());

    let allocation_count: Int = literal.elements.length();
    if (allocation_count == 0) { allocation_count = 1; }
    let data_size: UInt64 = UInt64(allocation_count) * element_layout.size;
    let raw_data: WirValueID = wir_call(
        ref program,
        state.block,
        wir_function_value(ref program, allocator_id),
        [wir_const_int(ref program, size_type, UInt128(data_size))],
        "",
        no_wir_location()
    );
    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [raw_data], [], no_wir_location());

    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let drop_id: WirFuncID = wir_vector_drop_function(ref types, ref source, ref program, source_type, element_type);
    let drop_address: WirValueID = wir_const_address(ref program, raw_pointer, wir_function_value(ref program, drop_id), 0L);
    let drop_slot: WirValueID = wir_cast(ref program, state.block, raw, wir_pointer_type(ref program, raw_pointer), "", no_wir_location());
    wir_store(ref program, state.block, drop_address, drop_slot, no_wir_location());

    let uint32_type: WirTypeID = wir_unsigned_int_type(ref program, 32);
    let refcount_slot: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE + WIR_ARC_REFCOUNT_OFFSET, wir_pointer_type(ref program, uint32_type));
    let type_slot: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE + WIR_ARC_TYPE_OFFSET, wir_pointer_type(ref program, uint32_type));
    wir_store(ref program, state.block, wir_const_int(ref program, uint32_type, UInt128(1U)), refcount_slot, no_wir_location());
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
        if ((argument.name.length() != 0) || argument.is_spread) {
            state.errors.append("Vector literal contains a named or spread element in WIR lowering");
            return wir_no_expr();
        }
        let element: WirExpr = wir_lower_expected_expr(ref state, ref types, ref source, ref program, argument.val, element_type);
        if (element.value == NO_WIR_VALUE) {
            return wir_no_expr();
        }
        element = wir_cast_expr(ref state, ref types, ref source, ref program, element, element_type, true, no_position());
        if (element.value == NO_WIR_VALUE) {
            return wir_no_expr();
        }
        wir_move_or_retain(ref state, ref types, ref source, ref program, element);
        let index: WirValueID = wir_const_int(ref program, size_type, UInt128(UIntSize(i)));
        wir_store(ref program, state.block, element.value, wir_index_address(ref program, state.block, data, index, "", no_wir_location()), no_wir_location());
        i++;
    }
    wir_track_owned(ref state, vector, source_type);
    return WirExpr(value=vector, source_type=source_type);
}

func wir_lower_variadic_source(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    argument: ArgNode,
    element_type: Int
) -> WirVariadicSource {
    if (!argument.is_spread) {
        let value: WirExpr = wir_lower_expected_expr(ref state, ref types, ref source, ref program, argument.val, element_type);
        if (value.value == NO_WIR_VALUE) {
            return WirVariadicSource(value=wir_no_expr(), spread=false, length=NO_WIR_VALUE, data=NO_WIR_VALUE);
        }
        value = wir_cast_expr(ref state, ref types, ref source, ref program, value, element_type, true, no_position());
        if (value.value == NO_WIR_VALUE) {
            return WirVariadicSource(value=wir_no_expr(), spread=false, length=NO_WIR_VALUE, data=NO_WIR_VALUE);
        }
        let one: WirValueID = wir_const_int(ref program, wir_unsigned_int_type(ref program, program.pointer_bits), UInt128(1U));
        return WirVariadicSource(value=value, spread=false, length=one, data=NO_WIR_VALUE);
    }

    let source_type: Int = get_repr_type(ref source, wir_argument_type(ref state, ref source, argument.val));
    let array: Optional(ArrayInfo) = source.array_info_map.lookup(source_type);
    let vector: Optional(SymbolInfo) = source.vector_base_map.lookup(source_type);
    let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
    let zero: WirValueID = wir_const_int(ref program, size_type, UInt128(0U));

    if ((array is !null)) {
        if (array.base_type != element_type) {
            state.errors.append("Cannot expand " + get_type_name(ref source, source_type) + " into a variadic parameter of " + get_type_name(ref source, element_type));
            return WirVariadicSource(value=wir_no_expr(), spread=true, length=NO_WIR_VALUE, data=NO_WIR_VALUE);
        }
        if (array.size >= 0) {
            let value: WirExpr = wir_lower_lvalue(ref state, ref types, ref source, ref program, argument.val);
            if (value.value == NO_WIR_VALUE) {
                return WirVariadicSource(value=wir_no_expr(), spread=true, length=NO_WIR_VALUE, data=NO_WIR_VALUE);
            }
            let length: WirValueID = wir_const_int(ref program, size_type, UInt128(UIntSize(array.size)));
            let data: WirValueID = wir_index_address(ref program, state.block, value.value, zero, "", no_wir_location());
            return WirVariadicSource(value=value, spread=true, length=length, data=data);
        }

        let value: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, argument.val);
        if (value.value == NO_WIR_VALUE) {
            return WirVariadicSource(value=wir_no_expr(), spread=true, length=NO_WIR_VALUE, data=NO_WIR_VALUE);
        }
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [value.value], [], no_wir_location());
        let start: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, value.value, 0, "", no_wir_location()), "", no_wir_location());
        let length: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, value.value, 1, "", no_wir_location()), "", no_wir_location());
        let data_slot: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, value.value, 3, "", no_wir_location()), "", no_wir_location());
        let data: WirValueID = wir_load(ref program, state.block, data_slot, "", no_wir_location());
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [data], [], no_wir_location());
        data = wir_index_address(ref program, state.block, data, start, "", no_wir_location());
        return WirVariadicSource(value=value, spread=true, length=length, data=data);
    }

    if ((vector is !null)) {
        if (vector.type != element_type) {
            state.errors.append("Cannot expand " + get_type_name(ref source, source_type) + " into a variadic parameter of " + get_type_name(ref source, element_type));
            return WirVariadicSource(value=wir_no_expr(), spread=true, length=NO_WIR_VALUE, data=NO_WIR_VALUE);
        }
        let value: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, argument.val);
        if (value.value == NO_WIR_VALUE) {
            return WirVariadicSource(value=wir_no_expr(), spread=true, length=NO_WIR_VALUE, data=NO_WIR_VALUE);
        }
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [value.value], [], no_wir_location());
        let length: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, value.value, 0, "", no_wir_location()), "", no_wir_location());
        let data: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, value.value, 2, "", no_wir_location()), "", no_wir_location());
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [data], [], no_wir_location());
        return WirVariadicSource(value=value, spread=true, length=length, data=data);
    }

    state.errors.append("Only an Array or Vector can be expanded into a variadic argument");
    return WirVariadicSource(value=wir_no_expr(), spread=true, length=NO_WIR_VALUE, data=NO_WIR_VALUE);
}

func wir_lower_variadic_pack(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    arguments: Vector(ArgNode),
    slice_type: Int
) -> WirExpr {
    let slice: Optional(ArrayInfo) = source.array_info_map.lookup(get_repr_type(ref source, slice_type));
    if (!(slice is !null) || slice.size >= 0) {
        state.errors.append("Variadic parameter does not have an Array view type in WIR lowering");
        return wir_no_expr();
    }
    let meta_slice: ArrayInfo = slice;
    let element_type: Int = meta_slice.base_type;
    let element_wir: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, element_type);
    let element_layout: WirTypeLayout = wir_lowering_layout(ref types, program, element_wir);
    if (!element_layout.valid || element_layout.size == 0UL) {
        state.errors.append("Variadic element layout is unavailable during WIR lowering");
        return wir_no_expr();
    }

    let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
    let total: WirValueID = wir_const_int(ref program, size_type, UInt128(0U));
    let maximum: UInt128 = wir_integer_max(TYPE_UINTSIZE) / UInt128(element_layout.size);
    let lowered: Vector(WirVariadicSource) = [];
    let i: Int = 0;
    while (arguments is !null && i < arguments.length()) {
        let item: WirVariadicSource = wir_lower_variadic_source(ref state, ref types, ref source, ref program, arguments[i], element_type);
        if (item.value.value == NO_WIR_VALUE || item.length == NO_WIR_VALUE) {
            return wir_no_expr();
        }
        let remaining: WirValueID = wir_binary(
            ref program,
            state.block,
            WirOpcode.Subtract,
            size_type,
            wir_const_int(ref program, size_type, maximum),
            total,
            "",
            no_wir_location()
        );
        let fits: WirValueID = wir_binary(ref program, state.block, WirOpcode.UnsignedLessEqual, program.bool_type, item.length, remaining, "", no_wir_location());
        wir_guard_cast(ref state, ref program, fits);
        total = wir_binary(ref program, state.block, WirOpcode.Add, size_type, total, item.length, "", no_wir_location());
        lowered.append(item);
        i++;
    }

    let vector_type: Int = get_vector_type_id(ref source, element_type);
    let vector_wir: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, vector_type);
    let vector_pointer: WirType = program.arena.types[wir_id_index(UInt32(vector_wir))];
    let payload: WirTypeLayout = wir_lowering_layout(ref types, program, vector_pointer.element);
    if (vector_pointer.kind != WirTypeKind.Pointer || !payload.valid || payload.size > UInt64(wir_max_object_size(program.data_layout)) - UInt64(WIR_OBJECT_HEADER_SIZE)) {
        state.errors.append("Variadic storage layout is unavailable during WIR lowering");
        return wir_no_expr();
    }

    let allocator: Optional(FuncInfo) = wir_compiler_link_function(ref source, "memory_alloc");
    if (!(allocator is !null)) {
        state.errors.append("Variadic packing requires the memory_alloc compiler link");
        return wir_no_expr();
    }
    let meta_allocator: FuncInfo = allocator;
    let allocator_id: WirFuncID = wir_find_function(program, meta_allocator.name);
    if (allocator_id == NO_WIR_FUNC) {
        allocator_id = wir_lower_function_decl(ref types, ref source, ref program, meta_allocator);
    }
    if (allocator_id == NO_WIR_FUNC) {
        return wir_no_expr();
    }

    let raw: WirValueID = wir_call(
        ref program,
        state.block,
        wir_function_value(ref program, allocator_id),
        [wir_const_int(ref program, size_type, UInt128(payload.size + UInt64(WIR_OBJECT_HEADER_SIZE)))],
        "",
        no_wir_location()
    );
    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [raw], [], no_wir_location());
    let zero: WirValueID = wir_const_int(ref program, size_type, UInt128(0U));
    let empty: WirValueID = wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, total, zero, "", no_wir_location());
    let allocation_count: WirValueID = wir_binary(
        ref program,
        state.block,
        WirOpcode.Add,
        size_type,
        total,
        wir_cast(ref program, state.block, empty, size_type, "", no_wir_location()),
        "",
        no_wir_location()
    );
    let bytes: WirValueID = wir_binary(
        ref program,
        state.block,
        WirOpcode.Multiply,
        size_type,
        allocation_count,
        wir_const_int(ref program, size_type, UInt128(element_layout.size)),
        "",
        no_wir_location()
    );
    let raw_data: WirValueID = wir_call(ref program, state.block, wir_function_value(ref program, allocator_id), [bytes], "", no_wir_location());
    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [raw_data], [], no_wir_location());

    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let drop_id: WirFuncID = wir_vector_drop_function(ref types, ref source, ref program, vector_type, element_type);
    let drop_slot: WirValueID = wir_cast(ref program, state.block, raw, wir_pointer_type(ref program, raw_pointer), "", no_wir_location());
    wir_store(ref program, state.block, wir_const_address(ref program, raw_pointer, wir_function_value(ref program, drop_id), 0L), drop_slot, no_wir_location());
    let uint32_type: WirTypeID = wir_unsigned_int_type(ref program, 32);
    let refcount_slot: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE + WIR_ARC_REFCOUNT_OFFSET, wir_pointer_type(ref program, uint32_type));
    let type_slot: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE + WIR_ARC_TYPE_OFFSET, wir_pointer_type(ref program, uint32_type));
    wir_store(ref program, state.block, wir_const_int(ref program, uint32_type, UInt128(1U)), refcount_slot, no_wir_location());
    wir_store(ref program, state.block, wir_const_int(ref program, uint32_type, UInt128(UInt32(vector_type))), type_slot, no_wir_location());

    let vector: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE, vector_wir);
    let length_slot: WirValueID = wir_field_address(ref program, state.block, vector, 0, "", no_wir_location());
    let capacity_slot: WirValueID = wir_field_address(ref program, state.block, vector, 1, "", no_wir_location());
    let data_slot: WirValueID = wir_field_address(ref program, state.block, vector, 2, "", no_wir_location());
    let data_type: WirTypeID = program.arena.types[wir_id_index(UInt32(vector_pointer.element))].fields[2];
    let data: WirValueID = wir_cast(ref program, state.block, raw_data, data_type, "", no_wir_location());
    wir_store(ref program, state.block, total, length_slot, no_wir_location());
    wir_store(ref program, state.block, total, capacity_slot, no_wir_location());
    wir_store(ref program, state.block, data, data_slot, no_wir_location());

    let destination_slot: WirValueID = wir_stack_alloc(ref program, state.entry, size_type, "variadic.index", no_wir_location());
    wir_store(ref program, state.block, zero, destination_slot, no_wir_location());
    i = 0;
    while (i < lowered.length()) {
        let item: WirVariadicSource = lowered[i];
        if (!item.spread) {
            let destination: WirValueID = wir_load(ref program, state.block, destination_slot, "", no_wir_location());
            wir_move_or_retain(ref state, ref types, ref source, ref program, item.value);
            wir_store(ref program, state.block, item.value.value, wir_index_address(ref program, state.block, data, destination, "", no_wir_location()), no_wir_location());
            let next: WirValueID = wir_binary(
                ref program,
                state.block,
                WirOpcode.Add,
                size_type,
                destination,
                wir_const_int(ref program, size_type, UInt128(1U)),
                "",
                no_wir_location()
            );
            wir_store(ref program, state.block, next, destination_slot, no_wir_location());
        } else {
            let source_slot: WirValueID = wir_stack_alloc(ref program, state.entry, size_type, "variadic.source", no_wir_location());
            wir_store(ref program, state.block, zero, source_slot, no_wir_location());
            let condition: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "variadic.copy.cond."), []);
            let body: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "variadic.copy.body."), []);
            let finish: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "variadic.copy.end."), []);
            wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(condition, [])], no_wir_location());

            state.block = condition;
            let source_index: WirValueID = wir_load(ref program, state.block, source_slot, "", no_wir_location());
            let more: WirValueID = wir_binary(ref program, state.block, WirOpcode.UnsignedLess, program.bool_type, source_index, item.length, "", no_wir_location());
            wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [more], [wir_edge(body, []), wir_edge(finish, [])], no_wir_location());

            state.block = body;
            let value: WirValueID = wir_load(
                ref program,
                state.block,
                wir_index_address(ref program, state.block, item.data, source_index, "", no_wir_location()),
                "",
                no_wir_location()
            );
            if (wir_value_needs_drop(ref source, element_type)) {
                wir_emit_ownership_value(ref state, ref types, ref source, ref program, value, element_type, true);
            }
            let destination: WirValueID = wir_load(ref program, state.block, destination_slot, "", no_wir_location());
            wir_store(ref program, state.block, value, wir_index_address(ref program, state.block, data, destination, "", no_wir_location()), no_wir_location());
            let next_source: WirValueID = wir_binary(
                ref program,
                state.block,
                WirOpcode.Add,
                size_type,
                source_index,
                wir_const_int(ref program, size_type, UInt128(1U)),
                "",
                no_wir_location()
            );
            let next_destination: WirValueID = wir_binary(
                ref program,
                state.block,
                WirOpcode.Add,
                size_type,
                destination,
                wir_const_int(ref program, size_type, UInt128(1U)),
                "",
                no_wir_location()
            );
            wir_store(ref program, state.block, next_source, source_slot, no_wir_location());
            wir_store(ref program, state.block, next_destination, destination_slot, no_wir_location());
            wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(condition, [])], no_wir_location());
            state.block = finish;
        }
        i++;
    }
    return wir_make_slice(ref state, ref types, ref source, ref program, slice_type, vector, data_slot, length_slot, zero, total, true);
}

func wir_lower_bound_call_arguments(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    bound: BoundCallArgs,
    parameters: Vector(Struct),
    skip: Int,
    variadic_param: Int,
    name: String,
    pos: Position
) -> WirCallArguments {
    let count: Int = parameters.length() - skip;
    if (!has_bound_args(bound) || bound.ordered.length() != count) {
        state.errors.append("Arguments to '" + name + "' could not be bound before WIR lowering");
        return WirCallArguments(valid=false, values=[]);
    }
    let pack_index: Int = variadic_param - 1;
    let values: Vector(WirValueID) = [];
    let i: Int = 0;
    while (i < count) {
        let parameter: TypeListNode = parameters[i + skip];
        let value: WirExpr = wir_no_expr();
        if (i == pack_index) {
            value = wir_lower_variadic_pack(ref state, ref types, ref source, ref program, bound.variadic, parameter.type);
        } else if (parameter.pass_mode == PARAM_REF) {
            value = wir_lower_address(ref state, ref types, ref source, ref program, bound.ordered[i].val, parameter.type, pos);
            if (value.value != NO_WIR_VALUE && value.source_type != parameter.type) {
                state.errors.append("Reference argument to '" + name + "' has the wrong type in WIR lowering");
                return WirCallArguments(valid=false, values=[]);
            }
        } else {
            value = wir_lower_expected_expr(ref state, ref types, ref source, ref program, bound.ordered[i].val, parameter.type);
            if (value.value != NO_WIR_VALUE) {
                value = wir_cast_expr(ref state, ref types, ref source, ref program, value, parameter.type, true, no_position());
            }
        }
        if (value.value == NO_WIR_VALUE) {
            return WirCallArguments(valid=false, values=[]);
        }
        values.append(value.value);
        i++;
    }
    return WirCallArguments(valid=true, values=values);
}

struct WirSliceRange(
    start: WirValueID,
    length: WirValueID
)

func wir_slice_range(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    node: SliceAccessNode,
    length: WirValueID
) -> WirSliceRange {
    let int_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, TYPE_INT);
    let zero: WirValueID = wir_const_int(ref program, int_type, UInt128(0U));
    let start: WirValueID = zero;
    let end: WirValueID = length;
    if (has_node(node.start_idx) || has_node(node.end_idx)) {
        if (!has_node(node.start_idx) || !has_node(node.end_idx)) {
            state.errors.append("slice bounds reached WIR lowering with one omitted endpoint");
            return WirSliceRange(start=NO_WIR_VALUE, length=NO_WIR_VALUE);
        }
        let start_expr: WirExpr = wir_lower_expected_expr(ref state, ref types, ref source, ref program, node.start_idx, TYPE_INT);
        let end_expr: WirExpr = wir_lower_expected_expr(ref state, ref types, ref source, ref program, node.end_idx, TYPE_INT);
        if (start_expr.value == NO_WIR_VALUE || end_expr.value == NO_WIR_VALUE) {
            return WirSliceRange(start=NO_WIR_VALUE, length=NO_WIR_VALUE);
        }
        start_expr = wir_cast_expr(ref state, ref types, ref source, ref program, start_expr, TYPE_INT, true, no_position());
        end_expr = wir_cast_expr(ref state, ref types, ref source, ref program, end_expr, TYPE_INT, true, no_position());
        if (start_expr.value == NO_WIR_VALUE || end_expr.value == NO_WIR_VALUE) {
            return WirSliceRange(start=NO_WIR_VALUE, length=NO_WIR_VALUE);
        }
        start = start_expr.value;
        end = end_expr.value;
    }

    let nonnegative: WirValueID = wir_binary(ref program, state.block, WirOpcode.SignedGreaterEqual, program.bool_type, start, zero, "", no_wir_location());
    let ordered: WirValueID = wir_binary(ref program, state.block, WirOpcode.SignedLessEqual, program.bool_type, start, end, "", no_wir_location());
    let within: WirValueID = wir_binary(ref program, state.block, WirOpcode.SignedLessEqual, program.bool_type, end, length, "", no_wir_location());
    wir_guard_cast(ref state, ref program, wir_bool_and(ref program, state.block, nonnegative, wir_bool_and(ref program, state.block, ordered, within)));

    let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
    let start_size: WirValueID = wir_cast(ref program, state.block, start, size_type, "", no_wir_location());
    let span: WirValueID = wir_binary(ref program, state.block, WirOpcode.Subtract, int_type, end, start, "", no_wir_location());
    let length_size: WirValueID = wir_cast(ref program, state.block, span, size_type, "", no_wir_location());
    return WirSliceRange(start=start_size, length=length_size);
}

func wir_slice_drop_function(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, slice_type: Int) -> WirFuncID {
    let name: String = "__wl_drop." + slice_type;
    let function_id: WirFuncID = wir_find_function(program, name);
    if (function_id != NO_WIR_FUNC) { return function_id; }

    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    function_id = wir_add_function(ref program, name, [wir_param("object", raw_pointer)], program.void_type, false, WirLinkage.Internal, WirABI.White);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let slice_wir: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, slice_type);
    let slice: WirValueID = wir_cast(ref program, entry, function.parameters[0], slice_wir, "", no_wir_location());
    let owner: WirValueID = wir_load(ref program, entry, wir_field_address(ref program, entry, slice, 2, "", no_wir_location()), "", no_wir_location());
    wir_release(ref program, entry, owner, no_wir_location());
    wir_return(ref program, entry, NO_WIR_VALUE, no_wir_location());
    return function_id;
}

func wir_make_slice(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    slice_type: Int,
    owner: WirValueID,
    data_slot: WirValueID,
    size_slot: WirValueID,
    start: WirValueID,
    length: WirValueID,
    owner_is_new: Bool
) -> WirExpr {
    let result_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, slice_type);
    if (result_type == NO_WIR_TYPE) {
        return wir_no_expr();
    }
    let pointer: WirType = program.arena.types[wir_id_index(UInt32(result_type))];
    let payload: WirTypeLayout = wir_lowering_layout(ref types, program, pointer.element);
    if (pointer.kind != WirTypeKind.Pointer || !payload.valid || payload.size > UInt64(wir_max_object_size(program.data_layout)) - UInt64(WIR_OBJECT_HEADER_SIZE)) {
        state.errors.append("slice storage layout is unavailable during WIR lowering");
        return wir_no_expr();
    }

    let allocator: Optional(FuncInfo) = wir_compiler_link_function(ref source, "memory_alloc");
    if (!(allocator is !null)) {
        state.errors.append("slice construction requires the memory_alloc compiler link");
        return wir_no_expr();
    }
    let allocator_id: WirFuncID = wir_find_function(program, allocator.name);
    if (allocator_id == NO_WIR_FUNC) {
        allocator_id = wir_lower_function_decl(ref types, ref source, ref program, allocator);
    }
    if (allocator_id == NO_WIR_FUNC) {
        return wir_no_expr();
    }

    let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let total_size: UInt64 = payload.size + UInt64(WIR_OBJECT_HEADER_SIZE);
    let raw: WirValueID = wir_call(
        ref program,
        state.block,
        wir_function_value(ref program, allocator_id),
        [wir_const_int(ref program, size_type, UInt128(total_size))],
        "",
        no_wir_location()
    );
    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [raw], [], no_wir_location());

    let drop_id: WirFuncID = wir_slice_drop_function(ref types, ref source, ref program, slice_type);
    let drop_slot: WirValueID = wir_cast(ref program, state.block, raw, wir_pointer_type(ref program, raw_pointer), "", no_wir_location());
    wir_store(ref program, state.block, wir_const_address(ref program, raw_pointer, wir_function_value(ref program, drop_id), 0L), drop_slot, no_wir_location());
    let uint32_type: WirTypeID = wir_unsigned_int_type(ref program, 32);
    let refcount_slot: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE + WIR_ARC_REFCOUNT_OFFSET, wir_pointer_type(ref program, uint32_type));
    let type_slot: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE + WIR_ARC_TYPE_OFFSET, wir_pointer_type(ref program, uint32_type));
    wir_store(ref program, state.block, wir_const_int(ref program, uint32_type, UInt128(1U)), refcount_slot, no_wir_location());
    wir_store(ref program, state.block, wir_const_int(ref program, uint32_type, UInt128(UInt32(slice_type))), type_slot, no_wir_location());

    let slice: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE, result_type);
    let opaque: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let owner_pointer: WirValueID = owner;
    if (wir_value_type(ref program, owner_pointer) != opaque) {
        owner_pointer = wir_cast(ref program, state.block, owner_pointer, opaque, "", no_wir_location());
    }
    if (!owner_is_new) {
        wir_retain(ref program, state.block, owner_pointer, no_wir_location());
    }
    wir_store(ref program, state.block, start, wir_field_address(ref program, state.block, slice, 0, "", no_wir_location()), no_wir_location());
    wir_store(ref program, state.block, length, wir_field_address(ref program, state.block, slice, 1, "", no_wir_location()), no_wir_location());
    wir_store(ref program, state.block, owner_pointer, wir_field_address(ref program, state.block, slice, 2, "", no_wir_location()), no_wir_location());
    wir_store(ref program, state.block, data_slot, wir_field_address(ref program, state.block, slice, 3, "", no_wir_location()), no_wir_location());
    wir_store(ref program, state.block, size_slot, wir_field_address(ref program, state.block, slice, 4, "", no_wir_location()), no_wir_location());
    wir_track_owned(ref state, slice, slice_type);
    return WirExpr(value=slice, source_type=slice_type);
}

func wir_copy_slice(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    slice_type: Int,
    element_type: Int,
    source_data: WirValueID,
    source_start: WirValueID,
    length: WirValueID
) -> WirExpr {
    let vector_type: Int = get_vector_type_id(ref source, element_type);
    let vector_wir: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, vector_type);
    let vector_pointer: WirType = program.arena.types[wir_id_index(UInt32(vector_wir))];
    let element_wir: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, element_type);
    let payload: WirTypeLayout = wir_lowering_layout(ref types, program, vector_pointer.element);
    let element_layout: WirTypeLayout = wir_lowering_layout(ref types, program, element_wir);
    if (vector_pointer.kind != WirTypeKind.Pointer || !payload.valid || !element_layout.valid || element_layout.size == 0UL) {
        state.errors.append("slice copy has no valid vector storage layout in WIR lowering");
        return wir_no_expr();
    }

    let allocator: Optional(FuncInfo) = wir_compiler_link_function(ref source, "memory_alloc");
    if (!(allocator is !null)) {
        state.errors.append("slice copy requires the memory_alloc compiler link");
        return wir_no_expr();
    }
    let allocator_id: WirFuncID = wir_find_function(program, allocator.name);
    if (allocator_id == NO_WIR_FUNC) {
        allocator_id = wir_lower_function_decl(ref types, ref source, ref program, allocator);
    }
    if (allocator_id == NO_WIR_FUNC) {
        return wir_no_expr();
    }

    let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
    let zero: WirValueID = wir_const_int(ref program, size_type, UInt128(0U));
    let empty: WirValueID = wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, length, zero, "", no_wir_location());
    let allocation_count: WirValueID = wir_binary(
        ref program,
        state.block,
        WirOpcode.Add,
        size_type,
        length,
        wir_cast(ref program, state.block, empty, size_type, "", no_wir_location()),
        "",
        no_wir_location()
    );
    let maximum_count: UInt128 = wir_integer_max(TYPE_UINTSIZE) / UInt128(element_layout.size);
    let fits: WirValueID = wir_binary(
        ref program,
        state.block,
        WirOpcode.UnsignedLessEqual,
        program.bool_type,
        allocation_count,
        wir_const_int(ref program, size_type, maximum_count),
        "",
        no_wir_location()
    );
    wir_guard_cast(ref state, ref program, fits);

    let object_size: UInt64 = payload.size + UInt64(WIR_OBJECT_HEADER_SIZE);
    let raw: WirValueID = wir_call(
        ref program,
        state.block,
        wir_function_value(ref program, allocator_id),
        [wir_const_int(ref program, size_type, UInt128(object_size))],
        "",
        no_wir_location()
    );
    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [raw], [], no_wir_location());
    let bytes: WirValueID = wir_binary(
        ref program,
        state.block,
        WirOpcode.Multiply,
        size_type,
        allocation_count,
        wir_const_int(ref program, size_type, UInt128(element_layout.size)),
        "",
        no_wir_location()
    );
    let raw_data: WirValueID = wir_call(ref program, state.block, wir_function_value(ref program, allocator_id), [bytes], "", no_wir_location());
    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [raw_data], [], no_wir_location());

    let opaque: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let drop_id: WirFuncID = wir_vector_drop_function(ref types, ref source, ref program, vector_type, element_type);
    let drop_slot: WirValueID = wir_cast(ref program, state.block, raw, wir_pointer_type(ref program, opaque), "", no_wir_location());
    wir_store(ref program, state.block, wir_const_address(ref program, opaque, wir_function_value(ref program, drop_id), 0L), drop_slot, no_wir_location());
    let uint32_type: WirTypeID = wir_unsigned_int_type(ref program, 32);
    let refcount_slot: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE + WIR_ARC_REFCOUNT_OFFSET, wir_pointer_type(ref program, uint32_type));
    let type_slot: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE + WIR_ARC_TYPE_OFFSET, wir_pointer_type(ref program, uint32_type));
    wir_store(ref program, state.block, wir_const_int(ref program, uint32_type, UInt128(1U)), refcount_slot, no_wir_location());
    wir_store(ref program, state.block, wir_const_int(ref program, uint32_type, UInt128(UInt32(vector_type))), type_slot, no_wir_location());

    let vector: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE, vector_wir);
    let length_slot: WirValueID = wir_field_address(ref program, state.block, vector, 0, "", no_wir_location());
    let capacity_slot: WirValueID = wir_field_address(ref program, state.block, vector, 1, "", no_wir_location());
    let data_slot: WirValueID = wir_field_address(ref program, state.block, vector, 2, "", no_wir_location());
    let data_type: WirTypeID = program.arena.types[wir_id_index(UInt32(vector_pointer.element))].fields[2];
    let data: WirValueID = wir_cast(ref program, state.block, raw_data, data_type, "", no_wir_location());
    wir_store(ref program, state.block, length, length_slot, no_wir_location());
    wir_store(ref program, state.block, length, capacity_slot, no_wir_location());
    wir_store(ref program, state.block, data, data_slot, no_wir_location());

    let index_slot: WirValueID = wir_stack_alloc(ref program, state.entry, size_type, "slice.index", no_wir_location());
    wir_store(ref program, state.block, zero, index_slot, no_wir_location());
    let condition: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "slice.copy.cond."), []);
    let body: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "slice.copy.body."), []);
    let finish: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "slice.copy.end."), []);
    wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(condition, [])], no_wir_location());

    state.block = condition;
    let index: WirValueID = wir_load(ref program, state.block, index_slot, "", no_wir_location());
    let more: WirValueID = wir_binary(ref program, state.block, WirOpcode.UnsignedLess, program.bool_type, index, length, "", no_wir_location());
    wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [more], [wir_edge(body, []), wir_edge(finish, [])], no_wir_location());

    state.block = body;
    let source_index: WirValueID = wir_binary(ref program, state.block, WirOpcode.Add, size_type, source_start, index, "", no_wir_location());
    let element: WirValueID = wir_load(
        ref program,
        state.block,
        wir_index_address(ref program, state.block, source_data, source_index, "", no_wir_location()),
        "",
        no_wir_location()
    );
    if (wir_value_needs_drop(ref source, element_type)) {
        wir_emit_ownership_value(ref state, ref types, ref source, ref program, element, element_type, true);
    }
    wir_store(ref program, state.block, element, wir_index_address(ref program, state.block, data, index, "", no_wir_location()), no_wir_location());
    let next: WirValueID = wir_binary(ref program, state.block, WirOpcode.Add, size_type, index, wir_const_int(ref program, size_type, UInt128(1U)), "", no_wir_location());
    wir_store(ref program, state.block, next, index_slot, no_wir_location());
    wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(condition, [])], no_wir_location());

    state.block = finish;
    return wir_make_slice(ref state, ref types, ref source, ref program, slice_type, vector, data_slot, length_slot, zero, length, true);
}

func wir_lower_slice_access(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: SliceAccessNode, shared: Bool) -> WirExpr {
    let target: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, node.target);
    if (target.value == NO_WIR_VALUE) {
        return wir_no_expr();
    }
    let target_type: Int = get_repr_type(ref source, target.source_type);
    let omitted: Bool = !has_node(node.start_idx) && !has_node(node.end_idx);

    if (target_type == TYPE_STRING) {
        if shared {
            if (!omitted) {
                throw_type_error(node.pos, "String views currently require a full slice expression.");
                return wir_no_expr();
            }
            return target;
        }
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [target.value], [], no_wir_location());
        let length: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, target.value, 1, "", no_wir_location()), "", no_wir_location());
        let range: WirSliceRange = wir_slice_range(ref state, ref types, ref source, ref program, node, length);
        if (range.start == NO_WIR_VALUE) {
            return wir_no_expr();
        }
        let int_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, TYPE_INT);
        let start: WirValueID = wir_cast(ref program, state.block, range.start, int_type, "", no_wir_location());
        let span: WirValueID = wir_cast(ref program, state.block, range.length, int_type, "", no_wir_location());
        let end: WirValueID = wir_binary(ref program, state.block, WirOpcode.Add, int_type, start, span, "", no_wir_location());
        let slice: Optional(FuncInfo) = wir_compiler_link_function(ref source, "string_slice");
        if (!(slice is !null)) {
            state.errors.append("String slice runtime function is unavailable during WIR lowering");
            return wir_no_expr();
        }
        let function_id: WirFuncID = wir_find_function(program, slice.name);
        if (function_id == NO_WIR_FUNC) {
            function_id = wir_lower_function_decl(ref types, ref source, ref program, slice);
        }
        if (function_id == NO_WIR_FUNC) {
            return wir_no_expr();
        }
        let result: WirValueID = wir_call(ref program, state.block, wir_function_value(ref program, function_id), [target.value, start, end], "", no_wir_location());
        wir_track_owned(ref state, result, target.source_type);
        return WirExpr(value=result, source_type=target.source_type);
    }

    let array: Optional(ArrayInfo) = source.array_info_map.lookup(target_type);
    let vector: Optional(SymbolInfo) = source.vector_base_map.lookup(target_type);
    if (!(array is !null) && !(vector is !null)) {
        state.errors.append("type " + get_type_name(ref source, target.source_type) + " reached unsupported slice lowering");
        return wir_no_expr();
    }

    let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
    let element_type: Int = 0;
    let source_data: WirValueID = NO_WIR_VALUE;
    let source_start: WirValueID = wir_const_int(ref program, size_type, UInt128(0U));
    let owner: WirValueID = NO_WIR_VALUE;
    let data_slot: WirValueID = NO_WIR_VALUE;
    let size_slot: WirValueID = NO_WIR_VALUE;
    let current_length: WirValueID = NO_WIR_VALUE;

    if ((vector is !null)) {
        element_type = vector.type;
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [target.value], [], no_wir_location());
        size_slot = wir_field_address(ref program, state.block, target.value, 0, "", no_wir_location());
        data_slot = wir_field_address(ref program, state.block, target.value, 2, "", no_wir_location());
        current_length = wir_load(ref program, state.block, size_slot, "", no_wir_location());
        source_data = wir_load(ref program, state.block, data_slot, "", no_wir_location());
        owner = target.value;
    } else if (array is !null && array.size < 0) {
        element_type = array.base_type;
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [target.value], [], no_wir_location());
        source_start = wir_load(ref program, state.block, wir_field_address(ref program, state.block, target.value, 0, "", no_wir_location()), "", no_wir_location());
        current_length = wir_load(ref program, state.block, wir_field_address(ref program, state.block, target.value, 1, "", no_wir_location()), "", no_wir_location());
        owner = wir_load(ref program, state.block, wir_field_address(ref program, state.block, target.value, 2, "", no_wir_location()), "", no_wir_location());
        data_slot = wir_load(ref program, state.block, wir_field_address(ref program, state.block, target.value, 3, "", no_wir_location()), "", no_wir_location());
        size_slot = wir_load(ref program, state.block, wir_field_address(ref program, state.block, target.value, 4, "", no_wir_location()), "", no_wir_location());
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [data_slot], [], no_wir_location());
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [size_slot], [], no_wir_location());
        let owner_size: WirValueID = wir_load(ref program, state.block, size_slot, "", no_wir_location());
        let source_end: WirValueID = wir_binary(ref program, state.block, WirOpcode.Add, size_type, source_start, current_length, "", no_wir_location());
        let valid: WirValueID = wir_binary(ref program, state.block, WirOpcode.UnsignedLessEqual, program.bool_type, source_end, owner_size, "", no_wir_location());
        wir_guard_cast(ref state, ref program, valid);
        source_data = wir_load(ref program, state.block, data_slot, "", no_wir_location());
    } else {
        if (array is null) { return wir_no_expr(); }
        if shared {
            state.errors.append("shared slice over fixed stack storage reached WIR lowering");
            return wir_no_expr();
        }
        element_type = array.base_type;
        current_length = wir_const_int(ref program, size_type, UInt128(UIntSize(array.size)));
        let fixed_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, target_type);
        let fixed_slot: WirValueID = wir_stack_alloc(ref program, state.entry, fixed_type, "slice.source", no_wir_location());
        wir_store(ref program, state.block, target.value, fixed_slot, no_wir_location());
        source_data = wir_index_address(ref program, state.block, fixed_slot, wir_const_int(ref program, size_type, UInt128(0U)), "", no_wir_location());
    }

    let length_int: WirExpr = wir_size_to_int(ref state, ref types, ref source, ref program, current_length);
    let range: WirSliceRange = wir_slice_range(ref state, ref types, ref source, ref program, node, length_int.value);
    if (range.start == NO_WIR_VALUE) {
        return wir_no_expr();
    }
    let absolute_start: WirValueID = wir_binary(ref program, state.block, WirOpcode.Add, size_type, source_start, range.start, "", no_wir_location());
    let slice_type: Int = get_slice_type_id(ref source, element_type);
    if (!shared) {
        return wir_copy_slice(ref state, ref types, ref source, ref program, slice_type, element_type, source_data, absolute_start, range.length);
    }
    return wir_make_slice(ref state, ref types, ref source, ref program, slice_type, owner, data_slot, size_slot, absolute_start, range.length, false);
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
    let state: WirFunctionLowering = WirFunctionLowering(
        function=function_id,
        return_type=TYPE_VOID,
        entry=entry,
        block=entry,
        bindings=[],
        loops=[],
        error_targets=[],
        owned_values=[],
        errors=[],
        terminated=false,
        next_block=0,
        binding_indices=null,
        indexed_bindings=0,
        reference_checked=false
    );

    let deinit: FuncInfo = FuncInfo(name="", base_name="", ret_type=0, arg_types=[], arg_names=[], is_varargs=false, ann_flags=0, compiler_link_name="", abi_name="", mutates_self=false, variadic_param=0, default_args=[], ref_body=NodeID(0U), ref_context=null, ref_bindings=null);
    let method_index: Int = 0;
    while (info.vtable is !null && method_index < info.vtable.length()) {
        let candidate: FuncInfo = info.vtable[method_index];
        if (candidate.base_name == "$deinit") {
            deinit = candidate;
            break;
        }
        method_index++;
    }
    if (has_func(deinit)) {
        let deinit_id: WirFuncID = wir_find_function(program, deinit.name);
        if (deinit_id == NO_WIR_FUNC) {
            deinit_id = wir_lower_function_decl(ref types, ref source, ref program, deinit);
        }
        if (deinit_id != NO_WIR_FUNC) {
            let deinit_function: WirFunction = program.arena.functions[wir_id_index(UInt32(deinit_id))];
            let deinit_signature: WirType = program.arena.types[wir_id_index(UInt32(deinit_function.type_id))];
            let receiver: WirValueID = object;
            if (deinit_signature.parameters.length() != 0 && wir_value_type(ref program, receiver) != deinit_signature.parameters[0]) {
                receiver = wir_cast(ref program, entry, receiver, deinit_signature.parameters[0], "", no_wir_location());
            }
            wir_call(ref program, entry, wir_function_value(ref program, deinit_id), [receiver], "", no_wir_location());
        }
    }

    let i: Int = 0;
    while (info.fields is !null && i < info.fields.length()) {
        let field: FieldInfo = info.fields[i];
        if (field.name != "_vptr" && wir_value_needs_drop(ref source, field.type)) {
            let address: WirValueID = wir_field_address(ref program, state.block, object, field.offset, "", no_wir_location());
            wir_emit_ownership_slot(ref state, ref types, ref source, ref program, address, field.type, false);
        }
        i++;
    }
    i = 0;
    while (i < state.errors.length()) {
        types.errors.append(state.errors[i]);
        i++;
    }
    wir_return(ref program, state.block, NO_WIR_VALUE, no_wir_location());
    return function_id;
}

func wir_call_class_field_initializers(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    info: StructInfo,
    object: WirValueID
) -> Void {
    if (info.parent_id != 0) {
        let parent: Optional(StructInfo) = source.struct_id_map.lookup(info.parent_id);
        if ((parent is !null)) {
            wir_call_class_field_initializers(ref state, ref types, ref source, ref program, parent, object);
        }
    }

    let initializer: Optional(FuncInfo) = source.func_table.lookup(info.name + "_$field_init");
    if (!(initializer is !null)) {
        return;
    }
    queue_generic_class_method(ref source, info, "$field_init");
    let function_id: WirFuncID = wir_find_function(program, initializer.name);
    if (function_id == NO_WIR_FUNC) {
        function_id = wir_lower_function_decl(ref types, ref source, ref program, initializer);
    }
    if (function_id == NO_WIR_FUNC) {
        return;
    }
    let self_type: WirTypeID = program.arena.types[wir_id_index(UInt32(program.arena.functions[wir_id_index(UInt32(function_id))].type_id))].parameters[0];
    let self: WirValueID = object;
    if (wir_value_type(ref program, self) != self_type) {
        self = wir_cast(ref program, state.block, self, self_type, "", no_wir_location());
    }
    wir_call(ref program, state.block, wir_function_value(ref program, function_id), [self], "", no_wir_location());
}

func wir_ensure_class_vtable(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, info: StructInfo) -> WirGlobalID {
    let name: String = wir_class_vtable_name(info);
    let table_id: WirGlobalID = wir_find_global(program, name);
    if (table_id != NO_WIR_GLOBAL) { return table_id; }

    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let entries: Vector(WirValueID) = [];
    let i: Int = 0;
    while (info.vtable is !null && i < info.vtable.length()) {
        let method_info: FuncInfo = info.vtable[i];
        let instance_template: Optional(GenericTemplate) = source.generic_instance_templates.lookup("" + info.type_id);
        let required: Bool = true;
        if ((instance_template is !null)) {
            required = source.generic_methods_queued.contains_key(info.name + "_" + method_info.base_name);
        }
        if (!required) {
            entries.append(wir_null(ref program, raw_pointer));
            i++;
            continue;
        }
        let function_id: WirFuncID = wir_find_function(program, method_info.name);
        if (function_id == NO_WIR_FUNC) {
            function_id = wir_lower_function_decl(ref types, ref source, ref program, method_info);
        }
        if (function_id == NO_WIR_FUNC) {
            types.errors.append("Vtable entry '" + info.name + "." + method_info.base_name + "' has no WIR function");
            return NO_WIR_GLOBAL;
        }
        entries.append(wir_const_address(ref program, raw_pointer, wir_function_value(ref program, function_id), 0L));
        i++;
    }

    let table_type: WirTypeID = wir_dispatch_table_type(ref types, ref program, entries.length());
    return wir_add_global(ref program, name, table_type, wir_const_aggregate(ref program, table_type, entries), WirLinkage.Internal, true);
}

func wir_lower_class_constructor(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, call: CallNode, info: StructInfo) -> WirExpr {
    let class_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, info.type_id);
    let class_pointer: WirType = program.arena.types[wir_id_index(UInt32(class_type))];
    if (class_pointer.kind != WirTypeKind.Pointer) {
        state.errors.append("class constructor reached WIR lowering without a pointer representation");
        return wir_no_expr();
    }
    let payload: WirTypeLayout = wir_lowering_layout(ref types, program, class_pointer.element);
    if (!payload.valid || payload.size > UInt64(wir_max_object_size(program.data_layout)) - UInt64(WIR_OBJECT_HEADER_SIZE)) {
        state.errors.append("class layout is too large for the target address space");
        return wir_no_expr();
    }

    let allocator: Optional(FuncInfo) = wir_compiler_link_function(ref source, "memory_alloc");
    if (!(allocator is !null)) {
        state.errors.append("memory allocator is not available during WIR lowering");
        return wir_no_expr();
    }
    let meta_allocator: FuncInfo = allocator;
    let allocator_id: WirFuncID = wir_find_function(program, meta_allocator.name);
    if (allocator_id == NO_WIR_FUNC) {
        allocator_id = wir_lower_function_decl(ref types, ref source, ref program, meta_allocator);
    }
    if (allocator_id == NO_WIR_FUNC) { return wir_no_expr(); }

    let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
    let total_size: UInt64 = payload.size + UInt64(WIR_OBJECT_HEADER_SIZE);
    let size: WirValueID = wir_const_int(ref program, size_type, UInt128(total_size));
    let raw: WirValueID = wir_call(ref program, state.block, wir_function_value(ref program, allocator_id), [size], "", no_wir_location());
    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [raw], [], no_wir_location());

    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let drop_id: WirFuncID = wir_class_drop_function(ref types, ref source, ref program, info);
    let drop_address: WirValueID = wir_const_address(ref program, raw_pointer, wir_function_value(ref program, drop_id), 0L);
    let drop_slot: WirValueID = wir_cast(ref program, state.block, raw, wir_pointer_type(ref program, raw_pointer), "", no_wir_location());
    wir_store(ref program, state.block, drop_address, drop_slot, no_wir_location());

    let uint32_type: WirTypeID = wir_unsigned_int_type(ref program, 32);
    let refcount_slot: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE + WIR_ARC_REFCOUNT_OFFSET, wir_pointer_type(ref program, uint32_type));
    let type_slot: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE + WIR_ARC_TYPE_OFFSET, wir_pointer_type(ref program, uint32_type));
    wir_store(ref program, state.block, wir_const_int(ref program, uint32_type, UInt128(1U)), refcount_slot, no_wir_location());
    wir_store(ref program, state.block, wir_const_int(ref program, uint32_type, UInt128(UInt32(info.type_id))), type_slot, no_wir_location());

    let object: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE, class_type);
    let field_index: Int = 0;
    while (info.fields is !null && field_index < info.fields.length()) {
        let field: FieldInfo = info.fields[field_index];
        let address: WirValueID = wir_field_address(ref program, state.block, object, field.offset, "", no_wir_location());
        if (field.name == "_vptr") {
            let table_id: WirGlobalID = wir_ensure_class_vtable(ref types, ref source, ref program, info);
            if (table_id == NO_WIR_GLOBAL) {
                state.errors.append("class dispatch table was not emitted before construction");
                return wir_no_expr();
            }
            wir_store(ref program, state.block, wir_global_value(ref program, table_id), address, no_wir_location());
        } else {
            wir_store(ref program, state.block, wir_const_zero(ref program, wir_lower_source_type(ref types, ref source, ref program, field.type)), address, no_wir_location());
        }
        field_index++;
    }

    wir_call_class_field_initializers(ref state, ref types, ref source, ref program, info, object);
    let initializer: Optional(FuncInfo) = source.func_table.lookup(info.name + "_$init");
    let argument_count: Int = 0;
    if (call.args is !null) { argument_count = call.args.length(); }
    if (!(initializer is !null)) {
        if (argument_count != 0) {
            state.errors.append("class constructor has arguments but no init method in WIR lowering");
            return wir_no_expr();
        }
    } else {
        let bound: BoundCallArgs = bind_native_args(call.args, initializer, 1, call.pos);
        let initializer_id: WirFuncID = wir_find_function(program, initializer.name);
        if (initializer_id == NO_WIR_FUNC) {
            initializer_id = wir_lower_function_decl(ref types, ref source, ref program, initializer);
        }
        if (initializer_id == NO_WIR_FUNC) {
            return wir_no_expr();
        }
        let owned_start: Int = state.owned_values.length();
        let lowered: WirCallArguments = wir_lower_bound_call_arguments(
            ref state,
            ref types,
            ref source,
            ref program,
            bound,
            initializer.arg_types,
            1,
            initializer.variadic_param,
            info.name + ".init",
            call.pos
        );
        if (!lowered.valid) {
            return wir_no_expr();
        }
        let arguments: Vector(WirValueID) = [object];
        let i: Int = 0;
        while (i < lowered.values.length()) {
            arguments.append(lowered.values[i]);
            i++;
        }
        wir_call(ref program, state.block, wir_function_value(ref program, initializer_id), arguments, "", no_wir_location());
        wir_cleanup_temporaries(ref state, ref types, ref source, ref program, owned_start);
    }

    wir_track_owned(ref state, object, info.type_id);
    return WirExpr(value=object, source_type=info.type_id);
}

func wir_lower_interface_value(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirExpr, target_type: Int) -> WirExpr {
    let class_info: Optional(StructInfo) = source.struct_id_map.lookup(get_repr_type(ref source, value.source_type));
    let interface_info: Optional(StructInfo) = source.struct_id_map.lookup(get_repr_type(ref source, target_type));
    if (!(class_info is !null) || !class_info.is_class || !(interface_info is !null) || !interface_info.is_interface) {
        return wir_no_expr();
    }
    let meta_class_info: StructInfo = class_info;
    let protocol: StructInfo = interface_info;
    let method_index: Int = 0;
    while (protocol.vtable is !null && method_index < protocol.vtable.length()) {
        let method_def: MethodDefNode = protocol.vtable[method_index];
        let uses_self: Bool = type_node_contains_self(source.arena, method_def.return_type);
        let param_index: Int = 0;
        while (!uses_self && method_def.params is !null && param_index < method_def.params.length()) {
            uses_self = type_node_contains_self(source.arena, method_def.params[param_index].type_tok);
            param_index++;
        }
        if uses_self {
            throw_type_error(no_position(), "Interface '" + interface_diagnostic_name(ref source, protocol.type_id) + "' uses Self and can only be used as a static constraint.");
            return wir_no_expr();
        }
        method_index++;
    }
    if (!class_has_interface(ref source, meta_class_info, protocol)) {
        let declared: String = "";
        let i: Int = 0;
        while (meta_class_info.interfaces is !null && i < meta_class_info.interfaces.length()) {
            let item: TypeListNode = meta_class_info.interfaces[i];
            if (declared.length() != 0) { declared += ", "; }
            declared += "" + item.type;
            i++;
        }
        throw_type_error(no_position(), "Class '" + meta_class_info.name + "' does not implement interface '" + protocol.name + "'.");
        return wir_no_expr();
    }
    let table_id: WirGlobalID = wir_find_global(program, wir_interface_table_name(meta_class_info, protocol));
    if (table_id == NO_WIR_GLOBAL) {
        let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
        let entries: Vector(WirValueID) = [];
        method_index = 0;
        while (protocol.vtable is !null && method_index < protocol.vtable.length()) {
            let required: MethodDefNode = protocol.vtable[method_index];
            let implementation: Optional(FuncInfo) = find_interface_implementation(ref source, meta_class_info, protocol, required);
            let function_id: WirFuncID = NO_WIR_FUNC;
            if ((implementation is !null)) {
                function_id = wir_find_function(program, implementation.name);
            }
            if (function_id == NO_WIR_FUNC && (implementation is !null)) {
                function_id = wir_lower_function_decl(ref types, ref source, ref program, implementation);
            }
            if (function_id == NO_WIR_FUNC) {
                state.errors.append("Interface method '" + protocol.name + "." + required.name_tok.value + "' has no WIR implementation");
                return wir_no_expr();
            }
            entries.append(wir_const_address(ref program, raw_pointer, wir_function_value(ref program, function_id), 0L));
            method_index++;
        }
        let table_type: WirTypeID = wir_dispatch_table_type(ref types, ref program, entries.length());
        table_id = wir_add_global(
            ref program,
            wir_interface_table_name(meta_class_info, protocol),
            table_type,
            wir_const_aggregate(ref program, table_type, entries),
            WirLinkage.Internal,
            true
        );
    }
    if (table_id == NO_WIR_GLOBAL) {
        state.errors.append("interface dispatch table was not emitted before conversion");
        return wir_no_expr();
    }

    let object: WirValueID = wir_cast(ref program, state.block, value.value, wir_opaque_pointer(ref types, ref program), "", no_wir_location());
    let interface_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, target_type);
    let result: WirValueID = wir_struct_value(ref program, state.block, interface_type, [object, wir_global_value(ref program, table_id)], "", no_wir_location());
    if (wir_take_owned(ref state, value.value)) {
        wir_track_owned(ref state, result, target_type);
    }
    return WirExpr(value=result, source_type=target_type);
}

func wir_size_to_int(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirValueID) -> WirExpr {
    let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
    let limit: WirValueID = wir_const_int(ref program, size_type, UInt128(2147483648UL));
    wir_append(ref program, state.block, WirOpcode.BoundsCheck, program.void_type, [value, limit], [], no_wir_location());
    let result_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, TYPE_INT);
    if (size_type == result_type) {
        return WirExpr(value=value, source_type=TYPE_INT);
    }
    return WirExpr(value=wir_cast(ref program, state.block, value, result_type, "", no_wir_location()), source_type=TYPE_INT);
}

func wir_lower_length_call(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    call: CallNode,
    access: FieldAccessNode
) -> WirMemberCall {
    if (access.field_name != "length") {
        return WirMemberCall(handled=false, value=wir_no_expr());
    }
    let argument_count: Int = 0;
    if (call.args is !null) { argument_count = call.args.length(); }
    if (argument_count != 0) {
        state.errors.append("length() reached WIR lowering with arguments");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }

    let value: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, access.obj);
    if (value.value == NO_WIR_VALUE) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    let source_type: Int = get_repr_type(ref source, value.source_type);
    if (source_type == TYPE_STRING) {
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [value.value], [], no_wir_location());
        let length_address: WirValueID = wir_field_address(ref program, state.block, value.value, 1, "", no_wir_location());
        return WirMemberCall(handled=true, value=WirExpr(value=wir_load(ref program, state.block, length_address, "", no_wir_location()), source_type=TYPE_INT));
    }

    let array: Optional(ArrayInfo) = source.array_info_map.lookup(source_type);
    if ((array is !null)) {
        if (array.size >= 0) {
            let int_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, TYPE_INT);
            return WirMemberCall(handled=true, value=WirExpr(value=wir_const_int(ref program, int_type, UInt128(UInt32(array.size))), source_type=TYPE_INT));
        }
        let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [value.value], [], no_wir_location());
        let start: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, value.value, 0, "", no_wir_location()), "", no_wir_location());
        let length: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, value.value, 1, "", no_wir_location()), "", no_wir_location());
        let size_slot: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, value.value, 4, "", no_wir_location()), "", no_wir_location());
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [size_slot], [], no_wir_location());
        let owner_size: WirValueID = wir_load(ref program, state.block, size_slot, "", no_wir_location());
        let end: WirValueID = wir_binary(ref program, state.block, WirOpcode.Add, size_type, start, length, "", no_wir_location());
        let one: WirValueID = wir_const_int(ref program, size_type, UInt128(1U));
        let upper_bound: WirValueID = wir_binary(ref program, state.block, WirOpcode.Add, size_type, owner_size, one, "", no_wir_location());
        wir_append(ref program, state.block, WirOpcode.BoundsCheck, program.void_type, [end, upper_bound], [], no_wir_location());
        return WirMemberCall(handled=true, value=wir_size_to_int(ref state, ref types, ref source, ref program, length));
    }

    let vector: Optional(SymbolInfo) = source.vector_base_map.lookup(source_type);
    if ((vector is !null)) {
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [value.value], [], no_wir_location());
        let length: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, value.value, 0, "", no_wir_location()), "", no_wir_location());
        return WirMemberCall(handled=true, value=wir_size_to_int(ref state, ref types, ref source, ref program, length));
    }
    return WirMemberCall(handled=false, value=wir_no_expr());
}

func wir_lower_string_call(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    call: CallNode,
    access: FieldAccessNode
) -> WirMemberCall {
    let object_type: Int = get_repr_type(ref source, wir_lvalue_type(ref state, ref source, access.obj));
    if (object_type != TYPE_STRING) {
        return WirMemberCall(handled=false, value=wir_no_expr());
    }

    let target: Optional(FuncInfo) = wir_compiler_link_function(ref source, "string_" + access.field_name);
    if (!(target is !null)) {
        return WirMemberCall(handled=false, value=wir_no_expr());
    }
    let meta_target: FuncInfo = target;
    if (!wir_check_fallible_call(ref source, call, meta_target.ret_type, access.field_name)) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    let argument_count: Int = 0;
    if (call.args is !null) { argument_count = call.args.length(); }
    if (meta_target.arg_types is null || argument_count + 1 != meta_target.arg_types.length()) {
        state.errors.append("String method '" + access.field_name + "' reached WIR lowering with the wrong argument count");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }

    let function_id: WirFuncID = wir_find_function(program, meta_target.name);
    if (function_id == NO_WIR_FUNC) {
        function_id = wir_lower_function_decl(ref types, ref source, ref program, meta_target);
    }
    if (function_id == NO_WIR_FUNC) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }

    let owned_start: Int = state.owned_values.length();
    let object: WirExpr = wir_lower_expected_expr(ref state, ref types, ref source, ref program, access.obj, TYPE_STRING);
    if (object.value == NO_WIR_VALUE) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    object = wir_cast_expr(ref state, ref types, ref source, ref program, object, TYPE_STRING, true, no_position());
    if (object.value == NO_WIR_VALUE) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    let arguments: Vector(WirValueID) = [object.value];

    let i: Int = 0;
    while (i < argument_count) {
        let argument: ArgNode = call.args[i];
        if ((argument.name.length() != 0) || argument.is_spread) {
            state.errors.append("Named and spread String method arguments must be bound before WIR lowering");
            return WirMemberCall(handled=true, value=wir_no_expr());
        }
        let parameter: TypeListNode = meta_target.arg_types[i + 1];
        let value: WirExpr = wir_no_expr();
        if (parameter.pass_mode == PARAM_REF) {
            value = wir_lower_address(ref state, ref types, ref source, ref program, argument.val, parameter.type, call.pos);
            if (value.value == NO_WIR_VALUE || value.source_type != parameter.type) {
                state.errors.append("Reference argument to String method '" + access.field_name + "' has the wrong type in WIR lowering");
                return WirMemberCall(handled=true, value=wir_no_expr());
            }
        } else {
            value = wir_lower_expected_expr(ref state, ref types, ref source, ref program, argument.val, parameter.type);
            if (value.value == NO_WIR_VALUE) {
                return WirMemberCall(handled=true, value=wir_no_expr());
            }
            value = wir_cast_expr(ref state, ref types, ref source, ref program, value, parameter.type, true, no_position());
            if (value.value == NO_WIR_VALUE) {
                return WirMemberCall(handled=true, value=wir_no_expr());
            }
        }
        arguments.append(value.value);
        i++;
    }

    let result: WirValueID = wir_call(ref program, state.block, wir_function_value(ref program, function_id), arguments, "", no_wir_location());
    wir_cleanup_temporaries(ref state, ref types, ref source, ref program, owned_start);
    if (wir_value_needs_drop(ref source, meta_target.ret_type)) {
        wir_track_owned(ref state, result, meta_target.ret_type);
    }
    return WirMemberCall(handled=true, value=WirExpr(value=result, source_type=meta_target.ret_type));
}

func wir_lower_vector_append(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    call: CallNode,
    access: FieldAccessNode
) -> WirMemberCall {
    if (access.field_name != "append") {
        return WirMemberCall(handled=false, value=wir_no_expr());
    }
    let source_type: Int = get_repr_type(ref source, wir_lvalue_type(ref state, ref source, access.obj));
    let vector: Optional(SymbolInfo) = source.vector_base_map.lookup(source_type);
    if (!(vector is !null)) {
        return WirMemberCall(handled=false, value=wir_no_expr());
    }
    let argument_count: Int = 0;
    if (call.args is !null) { argument_count = call.args.length(); }
    if (argument_count != 1) {
        state.errors.append("Vector append reached WIR lowering with the wrong argument count");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    let argument: ArgNode = call.args[0];
    if ((argument.name.length() != 0) || argument.is_spread) {
        state.errors.append("Named and spread Vector append arguments must be bound before WIR lowering");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    if (wir_lvalue_const(ref state, ref source, access.obj)) {
        state.errors.append("Vector append reached WIR lowering through a const value");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }

    let object: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, access.obj);
    if (object.value == NO_WIR_VALUE) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [object.value], [], no_wir_location());
    let element: WirExpr = wir_lower_expected_expr(ref state, ref types, ref source, ref program, argument.val, vector.type);
    if (element.value == NO_WIR_VALUE) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    element = wir_cast_expr(ref state, ref types, ref source, ref program, element, vector.type, true, no_position());
    if (element.value == NO_WIR_VALUE) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }

    let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
    let element_wir: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, vector.type);
    let element_layout: WirTypeLayout = wir_lowering_layout(ref types, program, element_wir);
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
    let resizer: Optional(FuncInfo) = wir_compiler_link_function(ref source, "memory_resize");
    if (!(resizer is !null)) {
        state.errors.append("Vector append requires the memory_resize compiler link");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    let resizer_id: WirFuncID = wir_find_function(program, resizer.name);
    if (resizer_id == NO_WIR_FUNC) {
        resizer_id = wir_lower_function_decl(ref types, ref source, ref program, resizer);
    }
    if (resizer_id == NO_WIR_FUNC) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    let old_data: WirValueID = wir_load(ref program, resize, data_address, "", no_wir_location());
    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let raw_data: WirValueID = wir_cast(ref program, resize, old_data, raw_pointer, "", no_wir_location());
    let new_raw_data: WirValueID = wir_call(ref program, resize, wir_function_value(ref program, resizer_id), [raw_data, bytes], "", no_wir_location());
    wir_append(ref program, resize, WirOpcode.NullCheck, program.void_type, [new_raw_data], [], no_wir_location());
    let data_type: WirTypeID = wir_value_type(ref program, old_data);
    let new_data: WirValueID = wir_cast(ref program, resize, new_raw_data, data_type, "", no_wir_location());
    wir_store(ref program, resize, new_data, data_address, no_wir_location());
    wir_store(ref program, resize, new_capacity, capacity_address, no_wir_location());
    wir_append(ref program, resize, WirOpcode.Jump, program.void_type, [], [wir_edge(push, [])], no_wir_location());

    state.block = push;
    let final_data: WirValueID = wir_load(ref program, push, data_address, "", no_wir_location());
    let slot: WirValueID = wir_index_address(ref program, push, final_data, size, "", no_wir_location());
    wir_move_or_retain(ref state, ref types, ref source, ref program, element);
    wir_store(ref program, state.block, element.value, slot, no_wir_location());
    let one: WirValueID = wir_const_int(ref program, size_type, UInt128(1U));
    let new_size: WirValueID = wir_binary(ref program, state.block, WirOpcode.Add, size_type, size, one, "", no_wir_location());
    wir_store(ref program, state.block, new_size, size_address, no_wir_location());
    return WirMemberCall(handled=true, value=WirExpr(value=NO_WIR_VALUE, source_type=TYPE_VOID));
}

func wir_lower_vector_drop(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    call: CallNode,
    access: FieldAccessNode
) -> WirMemberCall {
    if (access.field_name != "drop") {
        return WirMemberCall(handled=false, value=wir_no_expr());
    }
    let source_type: Int = get_repr_type(ref source, wir_lvalue_type(ref state, ref source, access.obj));
    let vector: Optional(SymbolInfo) = source.vector_base_map.lookup(source_type);
    if (!(vector is !null)) {
        return WirMemberCall(handled=false, value=wir_no_expr());
    }

    let argument_count: Int = 0;
    if (call.args is !null) { argument_count = call.args.length(); }
    if (argument_count != 0) {
        state.errors.append("Vector drop reached WIR lowering with the wrong argument count");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    if (wir_lvalue_const(ref state, ref source, access.obj)) {
        state.errors.append("Vector drop reached WIR lowering through a const value");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }

    let object: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, access.obj);
    if (object.value == NO_WIR_VALUE) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [object.value], [], no_wir_location());

    let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
    let size_address: WirValueID = wir_field_address(ref program, state.block, object.value, 0, "", no_wir_location());
    let data_address: WirValueID = wir_field_address(ref program, state.block, object.value, 2, "", no_wir_location());
    let size: WirValueID = wir_load(ref program, state.block, size_address, "", no_wir_location());
    let one: WirValueID = wir_const_int(ref program, size_type, UInt128(1U));
    let index: WirValueID = wir_binary(ref program, state.block, WirOpcode.Subtract, size_type, size, one, "", no_wir_location());
    wir_append(ref program, state.block, WirOpcode.BoundsCheck, program.void_type, [index, size], [], no_wir_location());

    let data: WirValueID = wir_load(ref program, state.block, data_address, "", no_wir_location());
    let slot: WirValueID = wir_index_address(ref program, state.block, data, index, "", no_wir_location());
    let result: WirValueID = wir_load(ref program, state.block, slot, "", no_wir_location());
    wir_store(ref program, state.block, index, size_address, no_wir_location());
    if (wir_value_needs_drop(ref source, vector.type)) {
        wir_track_owned(ref state, result, vector.type);
    }
    return WirMemberCall(handled=true, value=WirExpr(value=result, source_type=vector.type));
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

func wir_lower_interface_call(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    call: CallNode,
    access: FieldAccessNode,
    owner: StructInfo
) -> WirMemberCall {
    let slot: Int = 0;
    while (owner.vtable is !null && slot < owner.vtable.length()) {
        let candidate: MethodDefNode = owner.vtable[slot];
        if (candidate.name_tok.value == access.field_name) { break; }
        slot++;
    }
    if (owner.vtable is null || slot >= owner.vtable.length()) {
        return WirMemberCall(handled=false, value=wir_no_expr());
    }
    let method_node: MethodDefNode = owner.vtable[slot];
    let argument_count: Int = 0;
    if (call.args is !null) { argument_count = call.args.length(); }
    let parameter_count: Int = 0;
    if (method_node.params is !null) { parameter_count = method_node.params.length(); }
    let parameter_names: Vector(String) = [];
    let name_index: Int = 0;
    while (name_index < parameter_count) {
        parameter_names.append(method_node.params[name_index].name_tok.value);
        name_index++;
    }
    let found_bound = bind_call_args(call.args, parameter_names, 0, call.pos);
    if (found_bound is null || argument_count != parameter_count) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    let bound: Vector(ArgNode) = found_bound;

    let owned_start: Int = state.owned_values.length();
    let interface_value: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, access.obj);
    if (interface_value.value == NO_WIR_VALUE) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    let object: WirValueID = wir_field(ref program, state.block, interface_value.value, 0, "", no_wir_location());
    let table: WirValueID = wir_field(ref program, state.block, interface_value.value, 1, "", no_wir_location());
    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [object], [], no_wir_location());
    let slot_index: WirValueID = wir_const_int(ref program, wir_unsigned_int_type(ref program, program.pointer_bits), UInt128(UIntSize(slot)));
    let method_slot: WirValueID = wir_index_address(ref program, state.block, table, slot_index, "", no_wir_location());
    let callee: WirValueID = wir_load(ref program, state.block, method_slot, "", no_wir_location());
    let arguments: Vector(WirValueID) = [object];

    let i: Int = 0;
    while (i < argument_count) {
        let argument: ArgNode = bound[i];
        if (argument.is_spread) {
            state.errors.append("Spread argument reached WIR interface call lowering");
            return WirMemberCall(handled=true, value=wir_no_expr());
        }
        let parameter: ParamNode = method_node.params[i];
        let source_type: Int = interface_method_type(ref source, owner, parameter.type_tok);
        let value: WirExpr = wir_no_expr();
        if (parameter.pass_mode == PARAM_REF) {
            value = wir_lower_address(ref state, ref types, ref source, ref program, argument.val, source_type, call.pos);
            if (value.value == NO_WIR_VALUE || value.source_type != source_type) {
                state.errors.append("Reference argument to method '" + access.field_name + "' has the wrong type in WIR lowering");
                return WirMemberCall(handled=true, value=wir_no_expr());
            }
        } else {
            value = wir_lower_expected_expr(ref state, ref types, ref source, ref program, argument.val, source_type);
            if (value.value == NO_WIR_VALUE) {
                return WirMemberCall(handled=true, value=wir_no_expr());
            }
            value = wir_cast_expr(ref state, ref types, ref source, ref program, value, source_type, true, no_position());
            if (value.value == NO_WIR_VALUE) {
                return WirMemberCall(handled=true, value=wir_no_expr());
            }
        }
        arguments.append(value.value);
        i++;
    }

    let call_type: WirTypeID = wir_interface_call_type(ref types, ref source, ref program, owner, method_node);
    let result_type: Int = interface_method_type(ref source, owner, method_node.return_type);
    let result: WirValueID = wir_call_typed(ref program, state.block, callee, call_type, arguments, "", no_wir_location());
    wir_cleanup_temporaries(ref state, ref types, ref source, ref program, owned_start);
    if (wir_value_needs_drop(ref source, result_type)) {
        wir_track_owned(ref state, result, result_type);
    }
    return WirMemberCall(handled=true, value=WirExpr(value=result, source_type=result_type));
}

func wir_lower_linked_class_call(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    call: CallNode,
    owner: StructInfo,
    target: FuncInfo
) -> WirMemberCall {
    let link_name: String = target.compiler_link_name;
    let argument_count: Int = 0;
    if (call.args is !null) { argument_count = call.args.length(); }

    if (link_name == "zero_value") {
        if (argument_count != 0) {
            state.errors.append("zero_value reached WIR lowering with arguments");
            return WirMemberCall(handled=true, value=wir_no_expr());
        }
        let result_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, target.ret_type);
        return WirMemberCall(handled=true, value=WirExpr(value=wir_const_zero(ref program, result_type), source_type=target.ret_type));
    }

    if (link_name != "hash_value" && link_name != "values_equal") {
        state.errors.append("Compiler-linked method '" + owner.name + "." + target.base_name + "' is not lowered to WIR yet");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }

    let expected: Int = 1;
    if (link_name == "values_equal") { expected = 2; }
    if (argument_count != expected || target.arg_types is null || target.arg_types.length() != expected + 1) {
        state.errors.append("Compiler-linked method '" + owner.name + "." + target.base_name + "' reached WIR lowering with the wrong argument count");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }

    let key_parameter: TypeListNode = target.arg_types[1];
    let key_type: Int = key_parameter.type;

    let arguments: Vector(WirValueID) = [];
    let i: Int = 0;
    while (i < expected) {
        let argument: ArgNode = call.args[i];
        if ((argument.name.length() != 0) || argument.is_spread) {
            state.errors.append("Named or spread Dict key argument reached WIR lowering");
            return WirMemberCall(handled=true, value=wir_no_expr());
        }
        let value: WirExpr = wir_lower_expected_expr(ref state, ref types, ref source, ref program, argument.val, key_type);
        if (value.value == NO_WIR_VALUE) {
            return WirMemberCall(handled=true, value=wir_no_expr());
        }
        value = wir_cast_expr(ref state, ref types, ref source, ref program, value, key_type, true, no_position());
        if (value.value == NO_WIR_VALUE) {
            return WirMemberCall(handled=true, value=wir_no_expr());
        }
        arguments.append(value.value);
        i++;
    }

    let function_id: WirFuncID = NO_WIR_FUNC;
    if (link_name == "hash_value") {
        function_id = wir_dict_typed_hash_function(ref types, ref source, ref program, key_type);
    } else {
        function_id = wir_dict_typed_equal_function(ref types, ref source, ref program, key_type);
    }
    if (function_id == NO_WIR_FUNC) {
        state.errors.append("Typed Dict keys of type " + get_type_name(ref source, key_type) + " are not lowered to WIR yet");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    let result: WirValueID = wir_call(ref program, state.block, wir_function_value(ref program, function_id), arguments, "", no_wir_location());
    return WirMemberCall(handled=true, value=WirExpr(value=result, source_type=target.ret_type));
}

func wir_lower_super_call(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, call: CallNode) -> WirMemberCall {
    if (!has_node(call.callee) || node_tag(call.callee) != NODE_FIELD_ACCESS) {
        return WirMemberCall(handled=false, value=wir_no_expr());
    }
    let access: FieldAccessNode = get_field_access_node(ref source.arena, call.callee);
    if (!has_node(access.obj) || node_tag(access.obj) != NODE_SUPER) {
        return WirMemberCall(handled=false, value=wir_no_expr());
    }

    let self: WirBinding = wir_find_binding(ref state, "self")?;
    catch(err) {
        state.errors.append("super reached WIR lowering outside a method");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    let current: Optional(StructInfo) = source.struct_id_map.lookup(get_repr_type(ref source, self.source_type));
    if (!(current is !null) || !current.is_class || current.parent_id == 0) {
        state.errors.append("super reached WIR lowering in a class without a parent");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    let meta_current: StructInfo = current;
    let parent: Optional(StructInfo) = source.struct_id_map.lookup(meta_current.parent_id);
    if (!(parent is !null)) {
        state.errors.append("parent class metadata is unavailable during WIR lowering");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    let meta_parent: StructInfo = parent;

    let method_name: String = access.field_name;
    if (method_name == "init") { method_name = "$init"; }
    else if (method_name == "deinit") {
        method_name = "$deinit";
    }
    let target: Optional(FuncInfo) = source.func_table.lookup(meta_parent.name + "_" + method_name);
    if (!(target is !null)) {
        state.errors.append("parent method '" + access.field_name + "' is unavailable during WIR lowering");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    let meta_target: FuncInfo = target;
    let function_id: WirFuncID = wir_find_function(program, meta_target.name);
    if (function_id == NO_WIR_FUNC) {
        function_id = wir_lower_function_decl(ref types, ref source, ref program, meta_target);
    }
    if (function_id == NO_WIR_FUNC) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let bound: BoundCallArgs = bind_native_args(call.args, meta_target, 1, call.pos);

    let owned_start: Int = state.owned_values.length();
    let self_value: WirValueID = wir_load(ref program, state.block, self.address, "", no_wir_location());
    let parent_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, meta_parent.type_id);
    let parent_self: WirValueID = self_value;
    if (wir_value_type(ref program, parent_self) != parent_type) {
        parent_self = wir_cast(ref program, state.block, parent_self, parent_type, "", no_wir_location());
    }
    let lowered: WirCallArguments = wir_lower_bound_call_arguments(
        ref state,
        ref types,
        ref source,
        ref program,
        bound,
        meta_target.arg_types,
        1,
        meta_target.variadic_param,
        meta_parent.name + "." + access.field_name,
        call.pos
    );
    if (!lowered.valid) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    let arguments: Vector(WirValueID) = [parent_self];
    let i: Int = 0;
    while (i < lowered.values.length()) {
        arguments.append(lowered.values[i]);
        i++;
    }

    let result: WirValueID = wir_call(ref program, state.block, wir_function_value(ref program, function_id), arguments, "", no_wir_location());
    wir_cleanup_temporaries(ref state, ref types, ref source, ref program, owned_start);
    if (wir_value_needs_drop(ref source, meta_target.ret_type)) {
        wir_track_owned(ref state, result, meta_target.ret_type);
    }
    return WirMemberCall(handled=true, value=WirExpr(value=result, source_type=meta_target.ret_type));
}

func wir_lower_class_call(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, call: CallNode) -> WirMemberCall {
    if (!has_node(call.callee) || node_tag(call.callee) != NODE_FIELD_ACCESS) {
        return WirMemberCall(handled=false, value=wir_no_expr());
    }
    let access: FieldAccessNode = get_field_access_node(ref source.arena, call.callee);
    let object_type: Int = get_repr_type(ref source, wir_argument_type(ref state, ref source, access.obj));
    let owner: Optional(StructInfo) = source.struct_id_map.lookup(object_type);
    if (!(owner is !null) || (find_field(owner, access.field_name) is !null)) {
        return WirMemberCall(handled=false, value=wir_no_expr());
    }
    let meta_owner: StructInfo = owner;
    if (meta_owner.is_interface) {
        return wir_lower_interface_call(ref state, ref types, ref source, ref program, call, access, meta_owner);
    }
    if (!meta_owner.is_class) {
        return WirMemberCall(handled=false, value=wir_no_expr());
    }

    let slot: Int = 0;
    let target: Optional(FuncInfo) = null;
    while (meta_owner.vtable is !null && slot < meta_owner.vtable.length()) {
        let candidate: FuncInfo = meta_owner.vtable[slot];
        if (candidate.base_name == access.field_name) {
            target = candidate;
            break;
        }
        slot++;
    }
    if (!(target is !null)) { target = source.func_table.lookup(meta_owner.name + "_" + access.field_name); }
    if (!(target is !null)) {
        return WirMemberCall(handled=false, value=wir_no_expr());
    }
    let meta_target: FuncInfo = target;
    if (!wir_check_fallible_call(ref source, call, meta_target.ret_type, access.field_name)) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    if (meta_target.compiler_link_name is !null && meta_target.compiler_link_name.length() != 0) {
        return wir_lower_linked_class_call(ref state, ref types, ref source, ref program, call, meta_owner, meta_target);
    }
    if (wir_lvalue_const(ref state, ref source, access.obj) && meta_target.mutates_self) {
        throw_type_error(call.pos, "Cannot call mutating method '" + access.field_name + "' through const value");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }

    queue_generic_class_method(ref source, meta_owner, meta_target.base_name);

    let function_id: WirFuncID = wir_find_function(program, meta_target.name);
    if (function_id == NO_WIR_FUNC) {
        function_id = wir_lower_function_decl(ref types, ref source, ref program, meta_target);
    }
    if (function_id == NO_WIR_FUNC) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let bound: BoundCallArgs = bind_native_args(call.args, meta_target, 1, call.pos);

    let owned_start: Int = state.owned_values.length();
    let object: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, access.obj);
    if (object.value == NO_WIR_VALUE) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [object.value], [], no_wir_location());
    let table_slot: WirValueID = wir_field_address(ref program, state.block, object.value, 0, "", no_wir_location());
    let table: WirValueID = wir_load(ref program, state.block, table_slot, "", no_wir_location());
    let slot_index: WirValueID = wir_const_int(ref program, wir_unsigned_int_type(ref program, program.pointer_bits), UInt128(UIntSize(slot)));
    let method_slot: WirValueID = wir_index_address(ref program, state.block, table, slot_index, "", no_wir_location());
    let callee: WirValueID = wir_load(ref program, state.block, method_slot, "", no_wir_location());

    let lowered: WirCallArguments = wir_lower_bound_call_arguments(
        ref state,
        ref types,
        ref source,
        ref program,
        bound,
        meta_target.arg_types,
        1,
        meta_target.variadic_param,
        meta_owner.name + "." + access.field_name,
        call.pos
    );
    if (!lowered.valid) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    let signature: WirType = program.arena.types[wir_id_index(UInt32(function.type_id))];
    let receiver: WirValueID = object.value;
    if (signature.parameters.length() != 0 && wir_value_type(ref program, receiver) != signature.parameters[0]) {
        receiver = wir_cast(ref program, state.block, receiver, signature.parameters[0], "self", no_wir_location());
    }
    let arguments: Vector(WirValueID) = [receiver];
    let i: Int = 0;
    while (i < lowered.values.length()) {
        arguments.append(lowered.values[i]);
        i++;
    }

    let result: WirValueID = wir_call_typed(ref program, state.block, callee, function.type_id, arguments, "", no_wir_location());
    wir_cleanup_temporaries(ref state, ref types, ref source, ref program, owned_start);
    if (wir_value_needs_drop(ref source, meta_target.ret_type)) {
        wir_track_owned(ref state, result, meta_target.ret_type);
    }
    return WirMemberCall(handled=true, value=WirExpr(value=result, source_type=meta_target.ret_type));
}

func wir_lower_generic_method_call(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, call: CallNode) -> WirMemberCall {
    let callee: NodeID = call.callee;
    let explicit: Vector(NodeID) = call.type_args;
    if (has_node(callee) && node_tag(callee) == NODE_GENERIC_TYPE) {
        let generic_callee: GenericTypeNode = get_generic_type_node(ref source.arena, callee);
        callee = generic_callee.base_type;
        if (explicit.length() == 0) { explicit = generic_callee.type_args; }
    }
    if (!has_node(callee) || node_tag(callee) != NODE_FIELD_ACCESS) {
        return WirMemberCall(handled=false, value=wir_no_expr());
    }

    let access: FieldAccessNode = get_field_access_node(ref source.arena, callee);
    let owner_type: Int = get_repr_type(ref source, wir_argument_type(ref state, ref source, access.obj));
    let owner: Optional(StructInfo) = source.struct_id_map.lookup(owner_type);
    if (!(owner is !null) || !owner.is_class) {
        return WirMemberCall(handled=false, value=wir_no_expr());
    }
    let meta_owner: StructInfo = owner;

    let generic: Optional(GenericTemplate) = source.generic_methods.lookup(meta_owner.name + "_" + access.field_name);
    if (!(generic is !null)) {
        return WirMemberCall(handled=false, value=wir_no_expr());
    }
    let meta_generic: GenericTemplate = generic;

    let target: FuncInfo = FuncInfo(name="", base_name="", ret_type=0, arg_types=[], arg_names=[], is_varargs=false, ann_flags=0, compiler_link_name="", abi_name="", mutates_self=false, variadic_param=0, default_args=[], ref_body=NodeID(0U), ref_context=null, ref_bindings=null);
    if (source.generic_method_key.length() != 0) {
        let current: Optional(FuncInfo) = source.func_table.lookup(source.generic_method_key);
        if ((current is !null) && current.base_name == access.field_name) { target = current; }
    }
    if (!has_func(target)) {
        let type_arguments: Vector(Struct) = [];
        if (explicit.length() != 0) {
            let resolved = resolve_generic_method_args(ref source, meta_generic, explicit, [], call.pos);
            if (resolved is null) { return WirMemberCall(handled=true, value=wir_no_expr()); }
            type_arguments = resolved;
        } else {
            let definition: MethodDefNode = get_method_def_node(ref source.arena, meta_generic.node);
            let inferred: Dict(String, SymbolInfo) = Dict();
            let i: Int = 0;
            while (call.args is !null && definition.params is !null && i < call.args.length()) {
                let argument: ArgNode = call.args[i];
                let parameter_index: Int = generic_call_param(definition.params, argument, i);
                if (parameter_index >= 0) {
                    let actual_type: Int = wir_generic_argument_type(ref state, ref source, argument, definition.params[parameter_index]);
                    if (actual_type == TYPE_POISON || !infer_type_args(ref source, meta_generic, definition.params[parameter_index].type_tok, actual_type, inferred, call.pos)) {
                        return WirMemberCall(handled=true, value=wir_no_expr());
                    }
                }
                i++;
            }
            i = 0;
            while (i < meta_generic.type_params.length()) {
                let parameter: GenericParamNode = meta_generic.type_params[i];
                let actual: Optional(SymbolInfo) = inferred.lookup(parameter.name_tok.value);
                if (!(actual is !null)) {
                    return WirMemberCall(handled=true, value=wir_no_expr());
                }
                let meta_actual: SymbolInfo = actual;
                type_arguments.append(TypeListNode(type=meta_actual.type, pass_mode=0));
                i++;
            }
        }
        if (type_arguments is null) {
            return WirMemberCall(handled=true, value=wir_no_expr());
        }
        let registered = register_generic_method(ref source, meta_generic, meta_owner, type_arguments, call.pos);
        if (registered is null) { return WirMemberCall(handled=true, value=wir_no_expr()); }
        target = registered;
    }
    if (!has_func(target)) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    if (!wir_check_fallible_call(ref source, call, target.ret_type, access.field_name)) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }

    let function_id: WirFuncID = wir_find_function(program, target.name);
    if (function_id == NO_WIR_FUNC) {
        function_id = wir_lower_function_decl(ref types, ref source, ref program, target);
    }
    if (function_id == NO_WIR_FUNC) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let bound: BoundCallArgs = bind_native_args(call.args, target, 1, call.pos);

    let owned_start: Int = state.owned_values.length();
    let object: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, access.obj);
    if (object.value == NO_WIR_VALUE) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [object.value], [], no_wir_location());
    let lowered: WirCallArguments = wir_lower_bound_call_arguments(
        ref state,
        ref types,
        ref source,
        ref program,
        bound,
        target.arg_types,
        1,
        target.variadic_param,
        meta_owner.name + "." + access.field_name,
        call.pos
    );
    if (!lowered.valid) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    let signature: WirType = program.arena.types[wir_id_index(UInt32(function.type_id))];
    let receiver: WirValueID = object.value;
    if (signature.parameters.length() != 0 && wir_value_type(ref program, receiver) != signature.parameters[0]) {
        receiver = wir_cast(ref program, state.block, receiver, signature.parameters[0], "self", no_wir_location());
    }
    let arguments: Vector(WirValueID) = [receiver];
    let i: Int = 0;
    while (i < lowered.values.length()) {
        arguments.append(lowered.values[i]);
        i++;
    }

    let result: WirValueID = wir_call(ref program, state.block, wir_function_value(ref program, function_id), arguments, "", no_wir_location());
    wir_cleanup_temporaries(ref state, ref types, ref source, ref program, owned_start);
    if (wir_value_needs_drop(ref source, target.ret_type)) {
        wir_track_owned(ref state, result, target.ret_type);
    }
    return WirMemberCall(handled=true, value=WirExpr(value=result, source_type=target.ret_type));
}

func wir_call_class_method_value(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    object: WirExpr,
    owner: StructInfo,
    name: String,
    arguments_nodes: Vector(ArgNode),
    pos: Position
) -> WirExpr {
    let slot: Int = 0;
    let target: FuncInfo = FuncInfo(name="", base_name="", ret_type=0, arg_types=[], arg_names=[], is_varargs=false, ann_flags=0, compiler_link_name="", abi_name="", mutates_self=false, variadic_param=0, default_args=[], ref_body=NodeID(0U), ref_context=null, ref_bindings=null);
    while (owner.vtable is !null && slot < owner.vtable.length()) {
        let candidate: FuncInfo = owner.vtable[slot];
        if (candidate.base_name == name) {
            target = candidate;
            break;
        }
        slot++;
    }
    if (!has_func(target)) {
        state.errors.append("Method '" + name + "' is unavailable during WIR lowering");
        return wir_no_expr();
    }
    queue_generic_class_method(ref source, owner, target.base_name);
    let function_id: WirFuncID = wir_find_function(program, target.name);
    if (function_id == NO_WIR_FUNC) {
        function_id = wir_lower_function_decl(ref types, ref source, ref program, target);
    }
    if (function_id == NO_WIR_FUNC) {
        return wir_no_expr();
    }
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let expected: Int = target.arg_types.length() - 1;
    let argument_count: Int = 0;
    if (arguments_nodes is !null) { argument_count = arguments_nodes.length(); }
    if (argument_count != expected) {
        state.errors.append("Method '" + name + "' reached WIR lowering with the wrong argument count");
        return wir_no_expr();
    }

    let owned_start: Int = state.owned_values.length();
    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [object.value], [], no_wir_location());
    let table: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, object.value, 0, "", no_wir_location()), "", no_wir_location());
    let slot_value: WirValueID = wir_const_int(ref program, wir_unsigned_int_type(ref program, program.pointer_bits), UInt128(UIntSize(slot)));
    let callee: WirValueID = wir_load(ref program, state.block, wir_index_address(ref program, state.block, table, slot_value, "", no_wir_location()), "", no_wir_location());
    let signature: WirType = program.arena.types[wir_id_index(UInt32(function.type_id))];
    let receiver: WirValueID = object.value;
    if (signature.parameters.length() != 0 && wir_value_type(ref program, receiver) != signature.parameters[0]) {
        receiver = wir_cast(ref program, state.block, receiver, signature.parameters[0], "self", no_wir_location());
    }
    let arguments: Vector(WirValueID) = [receiver];
    let i: Int = 0;
    while (i < expected) {
        let argument: ArgNode = arguments_nodes[i];
        if ((argument.name.length() != 0) || argument.is_spread) {
            state.errors.append("Named or spread method argument reached WIR lowering");
            return wir_no_expr();
        }
        let parameter: TypeListNode = target.arg_types[i + 1];
        let value: WirExpr = wir_no_expr();
        if (parameter.pass_mode == PARAM_REF) {
            value = wir_lower_address(ref state, ref types, ref source, ref program, argument.val, parameter.type, pos);
            if (value.value == NO_WIR_VALUE || value.source_type != parameter.type) {
                state.errors.append("Reference argument to method '" + name + "' has the wrong type in WIR lowering");
                return wir_no_expr();
            }
        } else {
            value = wir_lower_expected_expr(ref state, ref types, ref source, ref program, argument.val, parameter.type);
            if (value.value == NO_WIR_VALUE) {
                return wir_no_expr();
            }
            value = wir_cast_expr(ref state, ref types, ref source, ref program, value, parameter.type, true, no_position());
            if (value.value == NO_WIR_VALUE) { return wir_no_expr(); }
        }
        arguments.append(value.value);
        i++;
    }
    let result: WirValueID = wir_call_typed(ref program, state.block, callee, function.type_id, arguments, "", no_wir_location());
    wir_cleanup_temporaries(ref state, ref types, ref source, ref program, owned_start);
    if (wir_value_needs_drop(ref source, target.ret_type)) {
        wir_track_owned(ref state, result, target.ret_type);
    }
    return WirExpr(value=result, source_type=target.ret_type);
}

func wir_call_class_method_values(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    object: WirExpr,
    owner: StructInfo,
    name: String,
    values: Vector(WirExpr)
) -> WirExpr {
    let slot: Int = 0;
    let target: FuncInfo = FuncInfo(name="", base_name="", ret_type=0, arg_types=[], arg_names=[], is_varargs=false, ann_flags=0, compiler_link_name="", abi_name="", mutates_self=false, variadic_param=0, default_args=[], ref_body=NodeID(0U), ref_context=null, ref_bindings=null);
    while (owner.vtable is !null && slot < owner.vtable.length()) {
        let candidate: FuncInfo = owner.vtable[slot];
        if (candidate.base_name == name) {
            target = candidate;
            break;
        }
        slot++;
    }
    if (!has_func(target)) {
        state.errors.append("Method '" + name + "' is unavailable during WIR lowering");
        return wir_no_expr();
    }
    let count: Int = 0;
    if (values is !null) { count = values.length(); }
    if (target.arg_types is null || count + 1 != target.arg_types.length()) {
        state.errors.append("Method '" + name + "' reached WIR lowering with the wrong argument count");
        return wir_no_expr();
    }

    queue_generic_class_method(ref source, owner, target.base_name);
    let function_id: WirFuncID = wir_find_function(program, target.name);
    if (function_id == NO_WIR_FUNC) {
        function_id = wir_lower_function_decl(ref types, ref source, ref program, target);
    }
    if (function_id == NO_WIR_FUNC) {
        return wir_no_expr();
    }
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];

    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [object.value], [], no_wir_location());
    let table: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, object.value, 0, "", no_wir_location()), "", no_wir_location());
    let slot_value: WirValueID = wir_const_int(ref program, wir_unsigned_int_type(ref program, program.pointer_bits), UInt128(UIntSize(slot)));
    let callee: WirValueID = wir_load(ref program, state.block, wir_index_address(ref program, state.block, table, slot_value, "", no_wir_location()), "", no_wir_location());
    let signature: WirType = program.arena.types[wir_id_index(UInt32(function.type_id))];
    let receiver: WirValueID = object.value;
    if (signature.parameters.length() != 0 && wir_value_type(ref program, receiver) != signature.parameters[0]) {
        receiver = wir_cast(ref program, state.block, receiver, signature.parameters[0], "self", no_wir_location());
    }
    let arguments: Vector(WirValueID) = [receiver];
    let i: Int = 0;
    while (i < count) {
        let parameter: TypeListNode = target.arg_types[i + 1];
        if (parameter.pass_mode == PARAM_REF) {
            state.errors.append("Reference arguments cannot be synthesized for protocol method '" + name + "'");
            return wir_no_expr();
        }
        let value: WirExpr = wir_cast_expr(ref state, ref types, ref source, ref program, values[i], parameter.type, true, no_position());
        if (value.value == NO_WIR_VALUE) {
            return wir_no_expr();
        }
        arguments.append(value.value);
        i++;
    }

    let result: WirValueID = wir_call_typed(ref program, state.block, callee, function.type_id, arguments, "", no_wir_location());
    if (wir_value_needs_drop(ref source, target.ret_type)) {
        wir_track_owned(ref state, result, target.ret_type);
    }
    return WirExpr(value=result, source_type=target.ret_type);
}

func wir_ordering_value(ref state: WirFunctionLowering, ref source: Compiler, name: String) -> Int {
    let ordering: Optional(StructInfo) = null;
    ordering = source.struct_table.lookup("comparison.Ordering");
    let field: Optional(FieldInfo) = find_field(ordering, name);
    if (!(ordering is !null) || !(field is !null)) {
        state.errors.append("Ordering." + name + " is unavailable during WIR lowering");
        return -1;
    }
    return field.offset;
}

func wir_ordering_result(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, less: WirValueID, greater: WirValueID) -> WirExpr {
    let ordering: Optional(StructInfo) = null;
    ordering = source.struct_table.lookup("comparison.Ordering");
    if (!(ordering is !null)) {
        state.errors.append("Ordering is unavailable during WIR lowering");
        return wir_no_expr();
    }
    let less_value: Int = wir_ordering_value(ref state, ref source, "Less");
    let equal_value: Int = wir_ordering_value(ref state, ref source, "Equal");
    let greater_value: Int = wir_ordering_value(ref state, ref source, "Greater");
    if (less_value < 0 || equal_value < 0 || greater_value < 0) {
        return wir_no_expr();
    }

    let ordering_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, ordering.type_id);
    let check_greater: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "compare.greater."), []);
    let use_less: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "compare.less."), []);
    let use_equal: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "compare.equal."), []);
    let use_greater: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "compare.greater.value."), []);
    let end: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "compare.end."), [wir_param("ordering", ordering_type)]);
    wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [less], [wir_edge(use_less, []), wir_edge(check_greater, [])], no_wir_location());
    wir_append(ref program, check_greater, WirOpcode.Branch, program.void_type, [greater], [wir_edge(use_greater, []), wir_edge(use_equal, [])], no_wir_location());
    wir_append(
        ref program,
        use_less,
        WirOpcode.Jump,
        program.void_type,
        [],
        [wir_edge(end, [wir_const_int(ref program, ordering_type, UInt128(UInt32(less_value)))])],
        no_wir_location()
    );
    wir_append(
        ref program,
        use_equal,
        WirOpcode.Jump,
        program.void_type,
        [],
        [wir_edge(end, [wir_const_int(ref program, ordering_type, UInt128(UInt32(equal_value)))])],
        no_wir_location()
    );
    wir_append(
        ref program,
        use_greater,
        WirOpcode.Jump,
        program.void_type,
        [],
        [wir_edge(end, [wir_const_int(ref program, ordering_type, UInt128(UInt32(greater_value)))])],
        no_wir_location()
    );
    state.block = end;
    let end_block: WirBlock = program.arena.blocks[wir_id_index(UInt32(end))];
    return WirExpr(value=end_block.parameters[0], source_type=ordering.type_id);
}

func wir_lower_builtin_protocol_call(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    call: CallNode,
    access: FieldAccessNode
) -> WirMemberCall {
    let receiver_type: Int = wir_argument_type(ref state, ref source, access.obj);
    let name: String = access.field_name;
    let available: Bool = false;
    if (name == "equals" && has_builtin_equal(ref source, receiver_type)) {
        available = (source.struct_table.lookup("comparison.Equal") is !null);
    } else if (name == "hash" && has_builtin_hash(ref source, receiver_type)) {
        available = (source.struct_table.lookup("hashing.Hash") is !null);
    } else if (name == "compare" && has_builtin_order(ref source, receiver_type)) {
        available = (source.struct_table.lookup("comparison.Comparable") is !null);
    } else if (name == "display" && has_builtin_display(ref source, receiver_type)) {
        available = (source.struct_table.lookup("formatting.Display") is !null);
    }
    if (!available) {
        return WirMemberCall(handled=false, value=wir_no_expr());
    }

    let expected: Int = 0;
    if (name == "equals" || name == "compare") { expected = 1; }
    let count: Int = 0;
    if (call.args is !null) { count = call.args.length(); }
    if (count != expected) {
        state.errors.append("Protocol method '" + name + "' reached WIR lowering with the wrong argument count");
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    let i: Int = 0;
    while (call.args is !null && i < call.args.length()) {
        let argument: ArgNode = call.args[i];
        if ((argument.name.length() != 0) || argument.is_spread) {
            state.errors.append("Named or spread protocol arguments must be bound before WIR lowering");
            return WirMemberCall(handled=true, value=wir_no_expr());
        }
        i++;
    }

    let owned_start: Int = state.owned_values.length();
    let receiver: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, access.obj);
    if (receiver.value == NO_WIR_VALUE) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    if (name == "display") {
        let result: WirExpr = wir_convert_to_string(ref state, ref types, ref source, ref program, receiver);
        return WirMemberCall(handled=true, value=result);
    }
    if (name == "hash") {
        let function_id: WirFuncID = wir_dict_typed_hash_function(ref types, ref source, ref program, receiver_type);
        if (function_id == NO_WIR_FUNC) {
            state.errors.append("Type " + get_type_name(ref source, receiver_type) + " has no WIR hash implementation");
            return WirMemberCall(handled=true, value=wir_no_expr());
        }
        let result: WirValueID = wir_call(ref program, state.block, wir_function_value(ref program, function_id), [receiver.value], "", no_wir_location());
        wir_cleanup_temporaries(ref state, ref types, ref source, ref program, owned_start);
        return WirMemberCall(handled=true, value=WirExpr(value=result, source_type=TYPE_INT));
    }

    let argument: ArgNode = call.args[0];
    let other: WirExpr = wir_lower_expected_expr(ref state, ref types, ref source, ref program, argument.val, receiver_type);
    if (other.value == NO_WIR_VALUE) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    other = wir_cast_expr(ref state, ref types, ref source, ref program, other, receiver_type, true, no_position());
    if (other.value == NO_WIR_VALUE) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }

    let repr: Int = get_repr_type(ref source, receiver_type);
    if (name == "equals") {
        let result: WirExpr = wir_no_expr();
        if (repr == TYPE_STRING) {
            result = wir_compare_strings(ref state, ref types, ref source, ref program, receiver, other, TOK_EE);
        } else {
            result = WirExpr(value=wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, receiver.value, other.value, "", no_wir_location()), source_type=TYPE_BOOL);
        }
        wir_cleanup_temporaries(ref state, ref types, ref source, ref program, owned_start);
        return WirMemberCall(handled=true, value=result);
    }

    let less: WirValueID = NO_WIR_VALUE;
    let greater: WirValueID = NO_WIR_VALUE;
    if (repr == TYPE_STRING) {
        let hook: WirValueID = wir_string_runtime(ref state, ref types, ref source, ref program, "string_compare");
        if (hook == NO_WIR_VALUE) {
            return WirMemberCall(handled=true, value=wir_no_expr());
        }
        let comparison: WirValueID = wir_call(ref program, state.block, hook, [receiver.value, other.value], "", no_wir_location());
        let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
        let zero: WirValueID = wir_const_int(ref program, int_type, UInt128(0U));
        less = wir_binary(ref program, state.block, WirOpcode.SignedLess, program.bool_type, comparison, zero, "", no_wir_location());
        greater = wir_binary(ref program, state.block, WirOpcode.SignedGreater, program.bool_type, comparison, zero, "", no_wir_location());
    } else {
        let less_opcode: WirOpcode = wir_comparison_opcode(repr, TOK_LT);
        let greater_opcode: WirOpcode = wir_comparison_opcode(repr, TOK_GT);
        if (less_opcode == WirOpcode.Invalid || greater_opcode == WirOpcode.Invalid) {
            state.errors.append("Type " + get_type_name(ref source, receiver_type) + " has no WIR ordering implementation");
            return WirMemberCall(handled=true, value=wir_no_expr());
        }
        less = wir_binary(ref program, state.block, less_opcode, program.bool_type, receiver.value, other.value, "", no_wir_location());
        greater = wir_binary(ref program, state.block, greater_opcode, program.bool_type, receiver.value, other.value, "", no_wir_location());
    }
    let result: WirExpr = wir_ordering_result(ref state, ref types, ref source, ref program, less, greater);
    wir_cleanup_temporaries(ref state, ref types, ref source, ref program, owned_start);
    return WirMemberCall(handled=true, value=result);
}

func wir_lower_protocol_comparison(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    left: WirExpr,
    right: WirExpr,
    token: Int
) -> WirMemberCall {
    if (left.source_type != right.source_type) {
        return WirMemberCall(handled=false, value=wir_no_expr());
    }
    let owner: Optional(StructInfo) = source.struct_id_map.lookup(get_repr_type(ref source, left.source_type));
    if (!(owner is !null) || !owner.is_class) {
        return WirMemberCall(handled=false, value=wir_no_expr());
    }

    let ordered: Bool = token == TOK_LT || token == TOK_LTE || token == TOK_GT || token == TOK_GTE;
    let protocol_name: String = "comparison.Equal";
    let method_name: String = "equals";
    if ordered {
        protocol_name = "comparison.Comparable";
        method_name = "compare";
    }
    let protocol: Optional(StructInfo) = null;
    protocol = source.struct_table.lookup(protocol_name);
    if (!(protocol is !null) || !implements_interface(ref source, owner.type_id, protocol.type_id)) {
        return WirMemberCall(handled=false, value=wir_no_expr());
    }

    let compared: WirExpr = wir_call_class_method_values(ref state, ref types, ref source, ref program, left, owner, method_name, [right]);
    if (compared.value == NO_WIR_VALUE) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    if (!ordered) {
        if (token == TOK_EE) {
            return WirMemberCall(handled=true, value=compared);
        }
        let inverted: WirValueID = wir_unary(ref program, state.block, WirOpcode.Not, program.bool_type, compared.value, "", no_wir_location());
        return WirMemberCall(handled=true, value=WirExpr(value=inverted, source_type=TYPE_BOOL));
    }

    let ordinal: Int = wir_ordering_value(ref state, ref source, "Less");
    let opcode: WirOpcode = WirOpcode.Equal;
    if (token == TOK_GT) { ordinal = wir_ordering_value(ref state, ref source, "Greater"); }
    else if (token == TOK_LTE) {
        ordinal = wir_ordering_value(ref state, ref source, "Greater");
        opcode = WirOpcode.NotEqual;
    } else if (token == TOK_GTE) {
        opcode = WirOpcode.NotEqual;
    }
    if (ordinal < 0) {
        return WirMemberCall(handled=true, value=wir_no_expr());
    }
    let type_id: WirTypeID = wir_value_type(ref program, compared.value);
    let expected: WirValueID = wir_const_int(ref program, type_id, UInt128(UInt32(ordinal)));
    let result: WirValueID = wir_binary(ref program, state.block, opcode, program.bool_type, compared.value, expected, "", no_wir_location());
    return WirMemberCall(handled=true, value=WirExpr(value=result, source_type=TYPE_BOOL));
}

func wir_lower_map_literal(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: NodeID, expected_type: Int) -> WirExpr {
    let literal: MapLitNode = get_map_lit_node(ref source.arena, node);
    let dict_info: Optional(StructInfo) = null;
    if (expected_type != TYPE_AUTO && expected_type != TYPE_POISON) {
        dict_info = source.struct_id_map.lookup(get_repr_type(ref source, expected_type));
    }
    if (!is_typed_dict(ref source, dict_info)) {
        dict_info = source.struct_table.lookup("Dict");
        if (!(dict_info is !null)) { dict_info = source.struct_table.lookup("dict.Dict"); }
    }
    if (!(dict_info is !null)) {
        state.errors.append("Dict is not available while lowering a map literal to WIR");
        return wir_no_expr();
    }
    let meta_dict_info: StructInfo = dict_info;

    let constructor_arguments: Vector(ArgNode) = [];
    if (!is_typed_dict(ref source, meta_dict_info)) {
        let capacity: Int = literal.pairs.length() * 2;
        if (capacity < 8) { capacity = 8; }
        let token: Token = Token(type=TOK_INT, value="" + capacity, line=literal.pos.ln, col=literal.pos.col);
        let capacity_node: NodeID = add_int_node(ref source.arena, IntNode(type=NODE_INT, tok=token, pos=literal.pos));
        constructor_arguments.append(ArgNode(val=capacity_node, name="", is_spread=false));
    }
    let constructor: CallNode = CallNode(type=NODE_CALL, callee=NO_NODE, args=constructor_arguments, type_args=[], pos=literal.pos, preserve_fallible=false);
    let result: WirExpr = wir_lower_class_constructor(ref state, ref types, ref source, ref program, constructor, meta_dict_info);
    if (result.value == NO_WIR_VALUE) {
        return wir_no_expr();
    }

    let i: Int = 0;
    while (literal.pairs is !null && i < literal.pairs.length()) {
        let pair: MapPairNode = literal.pairs[i];
        if (!is_typed_dict(ref source, meta_dict_info)) {
            let key_type: Int = wir_argument_type(ref state, ref source, pair.key);
            if (key_type != TYPE_POISON && !is_dict_key_type(ref source, get_repr_type(ref source, key_type))) {
                throw_type_error(literal.pos, "fatal: Dict key is not hashable");
                return wir_no_expr();
            }
        }
        let arguments: Vector(ArgNode) = [ArgNode(val=pair.key, name="", is_spread=false), ArgNode(val=pair.value, name="", is_spread=false)];
        let call_result: WirExpr = wir_call_class_method_value(ref state, ref types, ref source, ref program, result, meta_dict_info, "put", arguments, literal.pos);
        if (call_result.source_type == TYPE_POISON) {
            return wir_no_expr();
        }
        i++;
    }
    return result;
}

func wir_lower_dict_intrinsic(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, call: CallNode, info: FuncInfo) -> WirExpr {
    let expected: Int = 1;
    if (info.compiler_link_name == "dict_keys_equal") { expected = 2; }
    let argument_count: Int = 0;
    if (call.args is !null) { argument_count = call.args.length(); }
    if (argument_count != expected) {
        state.errors.append("Dict intrinsic reached WIR lowering with the wrong argument count");
        return wir_no_expr();
    }

    let variant: Optional(StructInfo) = source.struct_table.lookup("$Variant");
    if (!(variant is !null)) {
        state.errors.append("Variant is not registered during WIR lowering");
        return wir_no_expr();
    }
    let meta_variant: StructInfo = variant;
    let owned_start: Int = state.owned_values.length();
    let arguments: Vector(WirValueID) = [];
    let i: Int = 0;
    while (i < argument_count) {
        let argument: ArgNode = call.args[i];
        if ((argument.name.length() != 0) || argument.is_spread) {
            state.errors.append("Named or spread Dict intrinsic argument reached WIR lowering");
            return wir_no_expr();
        }
        let value: WirExpr = wir_lower_expected_expr(ref state, ref types, ref source, ref program, argument.val, meta_variant.type_id);
        if (value.value == NO_WIR_VALUE) {
            return wir_no_expr();
        }
        value = wir_cast_expr(ref state, ref types, ref source, ref program, value, meta_variant.type_id, true, no_position());
        if (value.value == NO_WIR_VALUE) {
            return wir_no_expr();
        }
        arguments.append(value.value);
        i++;
    }

    let function_id: WirFuncID = NO_WIR_FUNC;
    if (info.compiler_link_name == "dict_key_hash") {
        function_id = wir_dict_variant_hash_function(ref types, ref source, ref program, meta_variant.type_id);
    } else {
        function_id = wir_dict_variant_equal_function(ref types, ref source, ref program, meta_variant.type_id);
    }
    if (function_id == NO_WIR_FUNC) { return wir_no_expr(); }
    let result: WirValueID = wir_call(ref program, state.block, wir_function_value(ref program, function_id), arguments, "", no_wir_location());
    wir_cleanup_temporaries(ref state, ref types, ref source, ref program, owned_start);
    return WirExpr(value=result, source_type=info.ret_type);
}

func wir_is_numeric_literal(ref source: Compiler, node: NodeID) -> Bool {
    if (!has_node(node)) { return false; }
    let kind: Int = node_tag(node);
    if (kind == NODE_INT || kind == NODE_FLOAT) { return true; }
    if (kind != NODE_UNARYOP) { return false; }
    let unary: UnaryOpNode = get_unary_node(ref source.arena, node);
    if (unary.op_tok.type != TOK_PLUS && unary.op_tok.type != TOK_SUB) { return false; }
    return wir_is_numeric_literal(ref source, unary.node);
}

func wir_lower_expected_expr(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: NodeID, expected_type: Int) -> WirExpr {
    if (has_node(node) && is_union_type(ref source, expected_type)) {
        if (node_tag(node) == NODE_VECTOR_LIT) {
            let literal: VectorLitNode = get_vector_lit_node(ref source.arena, node);
            let member: Int = union_vector_target(ref source, expected_type, node, literal.pos);
            if (member == TYPE_POISON) { return wir_no_expr(); }
            return wir_lower_array_literal(ref state, ref types, ref source, ref program, node, member);
        }
        if (node_tag(node) == NODE_MAP_LIT) {
            let literal = get_map_lit_node(ref source.arena, node);
            let member = union_map_target(ref source, expected_type, node, literal.pos);
            if (member == TYPE_POISON) { return wir_no_expr(); }
            return wir_lower_map_literal(ref state, ref types, ref source, ref program, node, member);
        }
    }
    if (has_node(node) && node_tag(node) == NODE_MAP_LIT) {
        return wir_lower_map_literal(ref state, ref types, ref source, ref program, node, expected_type);
    }
    if (has_node(node) && node_tag(node) == NODE_VECTOR_LIT && expected_type != TYPE_AUTO && expected_type != TYPE_POISON) {
        return wir_lower_array_literal(ref state, ref types, ref source, ref program, node, expected_type);
    }
    if (has_node(node) && node_tag(node) == NODE_CALL && expected_type >= 100) {
        let call: CallNode = get_call_node(ref source.arena, node);
        let written_template: Optional(GenericTemplate) = wir_generic_constructor(ref source, call.callee);
        let context_type = expected_type;
        if ((written_template is !null)) {
            context_type = generic_constructor_context(ref source, written_template, expected_type);
        }
        let expected_info: Optional(StructInfo) = source.struct_id_map.lookup(get_repr_type(ref source, context_type));
        let expected_template: Optional(GenericTemplate) = source.generic_instance_templates.lookup("" + get_repr_type(ref source, context_type));
        if ((expected_info is !null) && (expected_template is !null) && call.type_args.length() == 0) {
            let written_info: Optional(StructInfo) = wir_struct_constructor(ref source, call.callee);
            let matches_template: Bool = (written_info is !null) && written_info.name == expected_template.name;
            if (!matches_template && (written_template is !null)) {
                matches_template = written_template.name == expected_template.name;
            }
            if matches_template {
                if (expected_info.is_class) {
                    return wir_lower_class_constructor(ref state, ref types, ref source, ref program, call, expected_info);
                }
                if (!expected_info.is_interface && !expected_info.is_enum) {
                    return wir_lower_struct_constructor(ref state, ref types, ref source, ref program, call, expected_info);
                }
            }
        }
    }
    let value: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, node);
    if (value.value == NO_WIR_VALUE || expected_type == TYPE_AUTO || expected_type == TYPE_POISON) {
        return value;
    }
    if (wir_is_numeric_literal(ref source, node) && wir_source_numeric(get_repr_type(ref source, value.source_type)) && wir_source_numeric(get_repr_type(ref source, expected_type))) {
        return wir_cast_expr(ref state, ref types, ref source, ref program, value, expected_type, false, no_position());
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

func wir_string_runtime(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, name: String) -> WirValueID {
    let info: Optional(FuncInfo) = wir_compiler_link_function(ref source, name);
    if (!(info is !null)) {
        state.errors.append("String conversion runtime function '" + name + "' is unavailable during WIR lowering");
        return NO_WIR_VALUE;
    }
    let function_id: WirFuncID = wir_find_function(program, info.name);
    if (function_id == NO_WIR_FUNC) {
        function_id = wir_lower_function_decl(ref types, ref source, ref program, info);
    }
    if (function_id == NO_WIR_FUNC) {
        state.errors.append("String conversion runtime function '" + name + "' has no WIR declaration");
        return NO_WIR_VALUE;
    }
    return wir_function_value(ref program, function_id);
}

func wir_bool_string(ref state: WirFunctionLowering, ref types: WirTypeMap, ref program: WirModule, value: WirValueID) -> WirExpr {
    let string_type: WirTypeID = wir_string_layout(ref types, ref program);
    let true_value: WirValueID = wir_lower_string_constant(ref types, ref program, "true");
    let false_value: WirValueID = wir_lower_string_constant(ref types, ref program, "false");
    let true_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "string.true."), []);
    let false_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "string.false."), []);
    let merge_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "string.bool."), [wir_param("value", string_type)]);
    wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [value], [wir_edge(true_block, []), wir_edge(false_block, [])], no_wir_location());
    wir_append(ref program, true_block, WirOpcode.Jump, program.void_type, [], [wir_edge(merge_block, [true_value])], no_wir_location());
    wir_append(ref program, false_block, WirOpcode.Jump, program.void_type, [], [wir_edge(merge_block, [false_value])], no_wir_location());
    state.block = merge_block;
    let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(merge_block))];
    return WirExpr(value=block.parameters[0], source_type=TYPE_STRING);
}

func wir_convert_to_string(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirExpr) -> WirExpr {
    let source_type: Int = get_repr_type(ref source, value.source_type);
    if (source_type == TYPE_STRING) {
        return WirExpr(value=value.value, source_type=TYPE_STRING);
    }
    if (source_type == TYPE_NULL || source_type == TYPE_NULLPTR) {
        return WirExpr(value=wir_lower_string_constant(ref types, ref program, "null"), source_type=TYPE_STRING);
    }
    if (source_type == TYPE_BOOL) {
        return wir_bool_string(ref state, ref types, ref program, value.value);
    }

    let hook_name: String = "";
    let argument_type: Int = source_type;
    if (source_type == TYPE_INT || source_type == TYPE_BYTE || source_type == TYPE_INT8 || source_type == TYPE_INT16 || source_type == TYPE_UINT16) {
        hook_name = "format_int";
        argument_type = TYPE_INT;
    } else if (source_type == TYPE_LONG || source_type == TYPE_UINT32 || source_type == TYPE_INTSIZE) {
        hook_name = "format_long";
        argument_type = TYPE_LONG;
    } else if (source_type == TYPE_UINT64 || source_type == TYPE_UINTSIZE) {
        hook_name = "format_uint64";
        argument_type = TYPE_UINT64;
    } else if (source_type == TYPE_INT128) {
        hook_name = "format_int128";
    } else if (source_type == TYPE_UINT128) {
        hook_name = "format_uint128";
    } else if (source_type == TYPE_FLOAT || source_type == TYPE_FLOAT32) {
        hook_name = "format_float";
        argument_type = TYPE_FLOAT;
    } else if (source_type == TYPE_CHAR) {
        hook_name = "utf8_encode_char";
    } else {
        state.errors.append("Type " + get_type_name(ref source, value.source_type) + " cannot be converted to String during WIR lowering");
        return wir_no_expr();
    }

    let argument: WirExpr = value;
    if (source_type != argument_type) {
        argument = wir_cast_expr(ref state, ref types, ref source, ref program, value, argument_type, false, no_position());
        if (argument.value == NO_WIR_VALUE) {
            return wir_no_expr();
        }
    }
    let hook: WirValueID = wir_string_runtime(ref state, ref types, ref source, ref program, hook_name);
    if (hook == NO_WIR_VALUE) { return wir_no_expr(); }
    let result: WirValueID = wir_call(ref program, state.block, hook, [argument.value], "", no_wir_location());
    wir_track_owned(ref state, result, TYPE_STRING);
    return WirExpr(value=result, source_type=TYPE_STRING);
}

func wir_compare_strings(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    left: WirExpr,
    right: WirExpr,
    token: Int
) -> WirExpr {
    let hook: WirValueID = wir_string_runtime(ref state, ref types, ref source, ref program, "string_compare");
    if (hook == NO_WIR_VALUE) {
        return wir_no_expr();
    }
    let comparison: WirValueID = wir_call(ref program, state.block, hook, [left.value, right.value], "", no_wir_location());
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let zero: WirValueID = wir_const_int(ref program, int_type, UInt128(0U));
    let opcode: WirOpcode = WirOpcode.Equal;
    if (token == TOK_NE) { opcode = WirOpcode.NotEqual; }
    return WirExpr(value=wir_binary(ref program, state.block, opcode, program.bool_type, comparison, zero, "", no_wir_location()), source_type=TYPE_BOOL);
}

func wir_compare_errors(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, left: WirExpr, right: WirExpr, token: Int) -> WirExpr {
    if (token != TOK_EE && token != TOK_NE) { return wir_no_expr(); }
    if (!is_error_type(ref source, left.source_type) || !is_error_type(ref source, right.source_type)) {
        return wir_no_expr();
    }

    let left_error: WirValueID = wir_error_value(ref state, ref types, ref source, ref program, left);
    let right_error: WirValueID = wir_error_value(ref state, ref types, ref source, ref program, right);
    if (left_error == NO_WIR_VALUE || right_error == NO_WIR_VALUE) {
        return wir_no_expr();
    }

    let left_domain: WirValueID = wir_field(ref program, state.block, left_error, 0, "", no_wir_location());
    let right_domain: WirValueID = wir_field(ref program, state.block, right_error, 0, "", no_wir_location());
    let left_code: WirValueID = wir_field(ref program, state.block, left_error, 1, "", no_wir_location());
    let right_code: WirValueID = wir_field(ref program, state.block, right_error, 1, "", no_wir_location());
    let same_domain: WirValueID = wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, left_domain, right_domain, "", no_wir_location());
    let same_code: WirValueID = wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, left_code, right_code, "", no_wir_location());
    let equal: WirValueID = wir_bool_and(ref program, state.block, same_domain, same_code);
    if (token == TOK_EE) {
        return WirExpr(value=equal, source_type=TYPE_BOOL);
    }
    return WirExpr(value=wir_unary(ref program, state.block, WirOpcode.Not, program.bool_type, equal, "", no_wir_location()), source_type=TYPE_BOOL);
}

func wir_is_enum_type(ref source: Compiler, source_type: Int) -> Bool {
    if (source_type == TYPE_GENERIC_ENUM) { return true; }
    let info: Optional(StructInfo) = source.struct_id_map.lookup(get_repr_type(ref source, source_type));
    return (info is !null) && info.is_enum;
}

func wir_binary_type(ref state: WirFunctionLowering, ref source: Compiler, left: WirExpr, right: WirExpr, left_node: NodeID, right_node: NodeID) -> Int {
    if (left.source_type == right.source_type) { return left.source_type; }
    let left_repr: Int = get_repr_type(ref source, left.source_type);
    let right_repr: Int = get_repr_type(ref source, right.source_type);
    if (!wir_source_numeric(left_repr) || !wir_source_numeric(right_repr)) { return TYPE_POISON; }
    if (left.source_type == TYPE_FLOAT || right.source_type == TYPE_FLOAT) { return TYPE_FLOAT; }
    if (left.source_type == TYPE_FLOAT32 || right.source_type == TYPE_FLOAT32) { return TYPE_FLOAT32; }

    if (is_signed_integer(left.source_type) != is_signed_integer(right.source_type)) {
        let left_bits: Int = get_type_bitwidth(left.source_type);
        let right_bits: Int = get_type_bitwidth(right.source_type);
        if (is_signed_integer(left.source_type) && left_bits > right_bits) { return left.source_type; }
        if (is_signed_integer(right.source_type) && right_bits > left_bits) { return right.source_type; }
        if (is_unsuffix_int_literal(ref source, left_node)) { return right.source_type; }
        if (is_unsuffix_int_literal(ref source, right_node)) { return left.source_type; }
        throw_type_error(no_position(), "Cannot mix signed and unsigned integers without an explicit conversion");
        return TYPE_POISON;
    }

    let left_bits: Int = get_type_bitwidth(left.source_type);
    let right_bits: Int = get_type_bitwidth(right.source_type);
    if (right_bits > left_bits) { return right.source_type; }
    if (left_bits > right_bits) { return left.source_type; }
    if (is_unsigned_integer(right.source_type)) { return right.source_type; }
    return left.source_type;
}

func wir_print_hook(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, name: String) -> WirValueID {
    let info: Optional(FuncInfo) = wir_compiler_link_function(ref source, name);
    if (!(info is !null)) {
        state.errors.append("Print runtime function '" + name + "' is unavailable during WIR lowering");
        return NO_WIR_VALUE;
    }
    let function_id: WirFuncID = wir_find_function(program, info.name);
    if (function_id == NO_WIR_FUNC) {
        function_id = wir_lower_function_decl(ref types, ref source, ref program, info);
    }
    if (function_id == NO_WIR_FUNC) {
        state.errors.append("Print runtime function '" + name + "' has no WIR declaration");
        return NO_WIR_VALUE;
    }
    return wir_function_value(ref program, function_id);
}

func wir_print_string(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirValueID) -> Bool {
    let hook: WirValueID = wir_print_hook(ref state, ref types, ref source, ref program, "print_bytes");
    if (hook == NO_WIR_VALUE) { return false; }

    let string_type: WirTypeID = wir_string_layout(ref types, ref program);
    let null_string: WirValueID = wir_null(ref program, string_type);
    let is_null: WirValueID = wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, value, null_string, "", no_wir_location());
    let null_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "print.null."), []);
    let value_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "print.value."), []);
    let end_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "print.end."), []);
    wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [is_null], [wir_edge(null_block, []), wir_edge(value_block, [])], no_wir_location());

    state.block = null_block;
    let opaque: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let no_data: WirValueID = wir_null(ref program, opaque);
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let zero: WirValueID = wir_const_int(ref program, int_type, UInt128(0U));
    wir_call(ref program, state.block, hook, [no_data, zero], "", no_wir_location());
    wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(end_block, [])], no_wir_location());

    state.block = value_block;
    let data_slot: WirValueID = wir_field_address(ref program, state.block, value, 0, "", no_wir_location());
    let length_slot: WirValueID = wir_field_address(ref program, state.block, value, 1, "", no_wir_location());
    let data: WirValueID = wir_load(ref program, state.block, data_slot, "", no_wir_location());
    let length: WirValueID = wir_load(ref program, state.block, length_slot, "", no_wir_location());
    data = wir_cast(ref program, state.block, data, opaque, "", no_wir_location());
    wir_call(ref program, state.block, hook, [data, length], "", no_wir_location());
    wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(end_block, [])], no_wir_location());

    state.block = end_block;
    return true;
}

func wir_print_formatted(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    value: WirValueID,
    source_type: Int,
    hook_name: String,
    argument_type: Int
) -> Bool {
    let hook: WirValueID = wir_print_hook(ref state, ref types, ref source, ref program, hook_name);
    if (hook == NO_WIR_VALUE) { return false; }
    let argument: WirValueID = value;
    if (source_type != argument_type) {
        let target: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, argument_type);
        argument = wir_cast(ref program, state.block, argument, target, "", no_wir_location());
    }
    let text: WirValueID = wir_call(ref program, state.block, hook, [argument], "", no_wir_location());
    if (!wir_print_string(ref state, ref types, ref source, ref program, text)) { return false; }
    wir_emit_ownership_value(ref state, ref types, ref source, ref program, text, TYPE_STRING, false);
    return true;
}

func wir_print_text(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, text: String) -> Bool {
    return wir_print_string(ref state, ref types, ref source, ref program, wir_lower_string_constant(ref types, ref program, text));
}

func wir_print_enum(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirValueID, info: StructInfo) -> Bool {
    let value_type: WirTypeID = wir_value_type(ref program, value);
    let end: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "print.enum.end."), []);
    let i: Int = 0;
    while (info.fields is !null && i < info.fields.length()) {
        let field: FieldInfo = info.fields[i];
        let matched: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "print.enum.value."), []);
        let next: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "print.enum.next."), []);
        let expected: WirValueID = wir_const_int(ref program, value_type, UInt128(UInt32(field.offset)));
        let equal: WirValueID = wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, value, expected, "", no_wir_location());
        wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [equal], [wir_edge(matched, []), wir_edge(next, [])], no_wir_location());

        state.block = matched;
        if (!wir_print_text(ref state, ref types, ref source, ref program, info.name + "." + field.name)) { return false; }
        wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(end, [])], no_wir_location());
        state.block = next;
        i++;
    }
    if (!wir_print_text(ref state, ref types, ref source, ref program, info.name + "(<unknown>)")) {
        return false;
    }
    wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(end, [])], no_wir_location());
    state.block = end;
    return true;
}

func wir_print_error(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirValueID) -> Bool {
    let domain: WirValueID = wir_field(ref program, state.block, value, 0, "", no_wir_location());
    let code: WirValueID = wir_field(ref program, state.block, value, 1, "", no_wir_location());
    let domain_type: WirTypeID = wir_value_type(ref program, domain);
    let end: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "print.error.end."), []);
    let i: Int = 0;
    while (i < source.error_types.length()) {
        let info: StructInfo = source.error_types[i];
        let matched: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "print.error.type."), []);
        let next: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "print.error.next."), []);
        let fingerprint: WirValueID = wir_const_int(ref program, domain_type, UInt128(type_fingerprint(ref source, info.type_id)));
        let equal: WirValueID = wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, domain, fingerprint, "", no_wir_location());
        wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [equal], [wir_edge(matched, []), wir_edge(next, [])], no_wir_location());

        state.block = matched;
        if (!wir_print_enum(ref state, ref types, ref source, ref program, code, info)) { return false; }
        wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(end, [])], no_wir_location());
        state.block = next;
        i++;
    }
    if (!wir_print_text(ref state, ref types, ref source, ref program, "Error(code=")) { return false; }
    if (!wir_print_value(ref state, ref types, ref source, ref program, WirExpr(value=code, source_type=TYPE_INT))) {
        return false;
    }
    if (!wir_print_text(ref state, ref types, ref source, ref program, ")")) { return false; }
    wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(end, [])], no_wir_location());
    state.block = end;
    return true;
}

func wir_print_sequence(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    data: WirValueID,
    length: WirValueID,
    element_type: Int
) -> Bool {
    let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
    let zero: WirValueID = wir_const_int(ref program, size_type, UInt128(0U));
    let index_slot: WirValueID = wir_stack_alloc(ref program, state.entry, size_type, "print.index", no_wir_location());
    wir_store(ref program, state.block, zero, index_slot, no_wir_location());
    if (!wir_print_text(ref state, ref types, ref source, ref program, "[")) { return false; }

    let condition: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "print.list.cond."), []);
    let body: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "print.list.body."), []);
    let separator: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "print.list.sep."), []);
    let end: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "print.list.end."), []);
    wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(condition, [])], no_wir_location());

    state.block = condition;
    let index: WirValueID = wir_load(ref program, state.block, index_slot, "", no_wir_location());
    let more: WirValueID = wir_binary(ref program, state.block, WirOpcode.UnsignedLess, program.bool_type, index, length, "", no_wir_location());
    wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [more], [wir_edge(body, []), wir_edge(end, [])], no_wir_location());

    state.block = body;
    let element: WirValueID = wir_load(ref program, state.block, wir_index_address(ref program, state.block, data, index, "", no_wir_location()), "", no_wir_location());
    if (!wir_print_value(ref state, ref types, ref source, ref program, WirExpr(value=element, source_type=element_type))) {
        return false;
    }
    let next: WirValueID = wir_binary(ref program, state.block, WirOpcode.Add, size_type, index, wir_const_int(ref program, size_type, UInt128(1U)), "", no_wir_location());
    wir_store(ref program, state.block, next, index_slot, no_wir_location());
    let has_separator: WirValueID = wir_binary(ref program, state.block, WirOpcode.UnsignedLess, program.bool_type, next, length, "", no_wir_location());
    wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [has_separator], [wir_edge(separator, []), wir_edge(condition, [])], no_wir_location());

    state.block = separator;
    if (!wir_print_text(ref state, ref types, ref source, ref program, ", ")) { return false; }
    wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(condition, [])], no_wir_location());

    state.block = end;
    return wir_print_text(ref state, ref types, ref source, ref program, "]");
}

func wir_print_array(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    value: WirValueID,
    source_type: Int,
    info: ArrayInfo
) -> Bool {
    let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
    let data: WirValueID = NO_WIR_VALUE;
    let length: WirValueID = NO_WIR_VALUE;
    if (info.size >= 0) {
        let array_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
        let slot: WirValueID = wir_stack_alloc(ref program, state.entry, array_type, "print.array", no_wir_location());
        wir_store(ref program, state.block, value, slot, no_wir_location());
        data = wir_index_address(ref program, state.block, slot, wir_const_int(ref program, size_type, UInt128(0U)), "", no_wir_location());
        length = wir_const_int(ref program, size_type, UInt128(UIntSize(info.size)));
    } else {
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [value], [], no_wir_location());
        let start: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, value, 0, "", no_wir_location()), "", no_wir_location());
        length = wir_load(ref program, state.block, wir_field_address(ref program, state.block, value, 1, "", no_wir_location()), "", no_wir_location());
        let data_slot: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, value, 3, "", no_wir_location()), "", no_wir_location());
        let size_slot: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, value, 4, "", no_wir_location()), "", no_wir_location());
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [data_slot], [], no_wir_location());
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [size_slot], [], no_wir_location());
        let owner_size: WirValueID = wir_load(ref program, state.block, size_slot, "", no_wir_location());
        let slice_end: WirValueID = wir_binary(ref program, state.block, WirOpcode.Add, size_type, start, length, "", no_wir_location());
        let valid: WirValueID = wir_binary(ref program, state.block, WirOpcode.UnsignedLessEqual, program.bool_type, slice_end, owner_size, "", no_wir_location());
        wir_guard_cast(ref state, ref program, valid);
        let base: WirValueID = wir_load(ref program, state.block, data_slot, "", no_wir_location());
        data = wir_index_address(ref program, state.block, base, start, "", no_wir_location());
    }
    return wir_print_sequence(ref state, ref types, ref source, ref program, data, length, info.base_type);
}

func wir_print_vector(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirValueID, element_type: Int) -> Bool {
    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [value], [], no_wir_location());
    let length: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, value, 0, "", no_wir_location()), "", no_wir_location());
    let data: WirValueID = wir_load(ref program, state.block, wir_field_address(ref program, state.block, value, 2, "", no_wir_location()), "", no_wir_location());
    return wir_print_sequence(ref state, ref types, ref source, ref program, data, length, element_type);
}

func wir_has_display_protocol(ref source: Compiler, info: StructInfo) -> Bool {
    if (!has_struct(info)) { return false; }
    let display: Optional(StructInfo) = source.struct_table.lookup("formatting.Display");
    return (display is !null) && implements_interface(ref source, info.type_id, display.type_id);
}

func wir_print_class_display(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirValueID, info: StructInfo) -> Bool {
    let class_type: WirTypeID = wir_value_type(ref program, value);
    let is_null: WirValueID = wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, value, wir_null(ref program, class_type), "", no_wir_location());
    let null_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "print.display.null."), []);
    let value_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "print.display.value."), []);
    let end: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "print.display.end."), []);
    wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [is_null], [wir_edge(null_block, []), wir_edge(value_block, [])], no_wir_location());

    state.block = null_block;
    if (!wir_print_text(ref state, ref types, ref source, ref program, "null")) { return false; }
    wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(end, [])], no_wir_location());

    state.block = value_block;
    let text: WirExpr = wir_call_class_method_values(ref state, ref types, ref source, ref program, WirExpr(value=value, source_type=info.type_id), info, "display", []);
    if (text.value == NO_WIR_VALUE || get_repr_type(ref source, text.source_type) != TYPE_STRING) {
        state.errors.append("Display implementation for '" + info.name + "' did not return String");
        return false;
    }
    if (!wir_print_string(ref state, ref types, ref source, ref program, text.value)) { return false; }
    if (wir_take_owned(ref state, text.value)) {
        wir_emit_ownership_value(ref state, ref types, ref source, ref program, text.value, text.source_type, false);
    }
    wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(end, [])], no_wir_location());
    state.block = end;
    return true;
}

func wir_print_interface_display(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirValueID, info: StructInfo) -> Bool {
    let slot: Int = 0;
    while (info.vtable is !null && slot < info.vtable.length()) {
        let candidate: MethodDefNode = info.vtable[slot];
        if (candidate.name_tok.value == "display") { break; }
        slot++;
    }
    if (info.vtable is null || slot >= info.vtable.length()) {
        state.errors.append("Display method is missing from interface '" + info.name + "'");
        return false;
    }
    let method_node: MethodDefNode = info.vtable[slot];
    let object: WirValueID = wir_field(ref program, state.block, value, 0, "", no_wir_location());
    let table: WirValueID = wir_field(ref program, state.block, value, 1, "", no_wir_location());
    let object_type: WirTypeID = wir_value_type(ref program, object);
    let is_null: WirValueID = wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, object, wir_null(ref program, object_type), "", no_wir_location());
    let null_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "print.interface.null."), []);
    let value_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "print.interface.value."), []);
    let end: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "print.interface.end."), []);
    wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [is_null], [wir_edge(null_block, []), wir_edge(value_block, [])], no_wir_location());

    state.block = null_block;
    if (!wir_print_text(ref state, ref types, ref source, ref program, "null")) { return false; }
    wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(end, [])], no_wir_location());

    state.block = value_block;
    let slot_value: WirValueID = wir_const_int(ref program, wir_unsigned_int_type(ref program, program.pointer_bits), UInt128(UIntSize(slot)));
    let callee: WirValueID = wir_load(ref program, state.block, wir_index_address(ref program, state.block, table, slot_value, "", no_wir_location()), "", no_wir_location());
    let call_type: WirTypeID = wir_interface_call_type(ref types, ref source, ref program, info, method_node);
    let result_type: Int = interface_method_type(ref source, info, method_node.return_type);
    let text: WirValueID = wir_call_typed(ref program, state.block, callee, call_type, [object], "", no_wir_location());
    if (get_repr_type(ref source, result_type) != TYPE_STRING) {
        state.errors.append("Display implementation for interface '" + info.name + "' did not return String");
        return false;
    }
    if (!wir_print_string(ref state, ref types, ref source, ref program, text)) { return false; }
    wir_emit_ownership_value(ref state, ref types, ref source, ref program, text, result_type, false);
    wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(end, [])], no_wir_location());
    state.block = end;
    return true;
}

func wir_print_struct(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirValueID, info: StructInfo) -> Bool {
    if (!wir_print_text(ref state, ref types, ref source, ref program, info.name + "(")) {
        return false;
    }
    let printed: Int = 0;
    let i: Int = 0;
    while (info.fields is !null && i < info.fields.length()) {
        let field: FieldInfo = info.fields[i];
        if (field.name != "_vptr") {
            if (printed != 0 && !wir_print_text(ref state, ref types, ref source, ref program, ", ")) {
                return false;
            }
            if (!wir_print_text(ref state, ref types, ref source, ref program, field.name + "=")) {
                return false;
            }
            let field_value: WirValueID = NO_WIR_VALUE;
            if (info.is_class) {
                wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [value], [], no_wir_location());
                field_value = wir_load(ref program, state.block, wir_field_address(ref program, state.block, value, field.offset, "", no_wir_location()), "", no_wir_location());
            } else {
                field_value = wir_field(ref program, state.block, value, field.offset, "", no_wir_location());
            }
            if (!wir_print_value(ref state, ref types, ref source, ref program, WirExpr(value=field_value, source_type=field.type))) {
                return false;
            }
            printed++;
        }
        i++;
    }
    return wir_print_text(ref state, ref types, ref source, ref program, ")");
}

func wir_print_value(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirExpr) -> Bool {
    if (is_union_type(ref source, get_repr_type(ref source, value.source_type))) {
        throw_type_error(no_position(), "Type " + get_type_name(ref source, value.source_type) + " cannot be printed.");
        return false;
    }
    let source_type: Int = get_repr_type(ref source, value.source_type);
    if (source_type == TYPE_STRING) {
        return wir_print_string(ref state, ref types, ref source, ref program, value.value);
    }
    if (source_type == TYPE_NULL || source_type == TYPE_NULLPTR) {
        return wir_print_string(ref state, ref types, ref source, ref program, wir_lower_string_constant(ref types, ref program, "null"));
    }
    if (source_type == TYPE_UINT64 || source_type == TYPE_UINTSIZE) {
        return wir_print_formatted(ref state, ref types, ref source, ref program, value.value, source_type, "format_uint64", TYPE_UINT64);
    }
    if (source_type == TYPE_INT128) {
        return wir_print_formatted(ref state, ref types, ref source, ref program, value.value, source_type, "format_int128", TYPE_INT128);
    }
    if (source_type == TYPE_UINT128) {
        return wir_print_formatted(ref state, ref types, ref source, ref program, value.value, source_type, "format_uint128", TYPE_UINT128);
    }
    if (source_type == TYPE_ANY_ERROR) {
        return wir_print_error(ref state, ref types, ref source, ref program, value.value);
    }

    let info: Optional(StructInfo) = null;
    info = source.struct_id_map.lookup(source_type);
    if ((info is !null)) {
        if (info.is_enum) {
            return wir_print_enum(ref state, ref types, ref source, ref program, value.value, info);
        }
        if (wir_has_display_protocol(ref source, info)) {
            if (info.is_interface) {
                return wir_print_interface_display(ref state, ref types, ref source, ref program, value.value, info);
            }
            if (info.is_class) {
                return wir_print_class_display(ref state, ref types, ref source, ref program, value.value, info);
            }
        }
        if (info.name != "$Variant" && !info.is_interface) {
            return wir_print_struct(ref state, ref types, ref source, ref program, value.value, info);
        }
    }
    let vector: Optional(SymbolInfo) = null;
    vector = source.vector_base_map.lookup(source_type);
    if ((vector is !null)) {
        return wir_print_vector(ref state, ref types, ref source, ref program, value.value, vector.type);
    }
    let array: Optional(ArrayInfo) = null;
    array = source.array_info_map.lookup(source_type);
    if ((array is !null)) {
        return wir_print_array(ref state, ref types, ref source, ref program, value.value, source_type, array);
    }

    let hook_name: String = "";
    let argument_type: Int = source_type;
    if (source_type == TYPE_CHAR) { hook_name = "print_char"; }
    else if (source_type == TYPE_BOOL) {
        hook_name = "print_bool";
    }
    else if (source_type == TYPE_INT || source_type == TYPE_INT8 || source_type == TYPE_INT16 || source_type == TYPE_UINT16 || source_type == TYPE_BYTE) {
        hook_name = "print_int";
        argument_type = TYPE_INT;
    } else if (source_type == TYPE_LONG || source_type == TYPE_UINT32 || source_type == TYPE_INTSIZE) {
        hook_name = "print_long";
        argument_type = TYPE_LONG;
    } else if (source_type == TYPE_FLOAT || source_type == TYPE_FLOAT32) {
        hook_name = "print_float";
        argument_type = TYPE_FLOAT;
    } else {
        state.errors.append("Type " + get_type_name(ref source, value.source_type) + " is not lowered through print yet");
        return false;
    }

    let hook: WirValueID = wir_print_hook(ref state, ref types, ref source, ref program, hook_name);
    if (hook == NO_WIR_VALUE) { return false; }
    let argument: WirValueID = value.value;
    if (argument_type != source_type) {
        let target: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, argument_type);
        argument = wir_cast(ref program, state.block, argument, target, "", no_wir_location());
    }
    wir_call(ref program, state.block, hook, [argument], "", no_wir_location());
    return true;
}

func wir_print_next(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    value: WirExpr,
    separator: WirExpr,
    printed_slot: WirValueID
) -> Bool {
    let separator_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "print.sep."), []);
    let value_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "print.value."), []);
    let finish_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "print.next."), []);
    let printed: WirValueID = wir_load(ref program, state.block, printed_slot, "", no_wir_location());
    wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [printed], [wir_edge(separator_block, []), wir_edge(value_block, [])], no_wir_location());

    state.block = separator_block;
    if (!wir_print_value(ref state, ref types, ref source, ref program, separator)) { return false; }
    wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(value_block, [])], no_wir_location());

    state.block = value_block;
    if (!wir_print_value(ref state, ref types, ref source, ref program, value)) { return false; }
    wir_store(ref program, state.block, wir_const_bool(ref program, true), printed_slot, no_wir_location());
    wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(finish_block, [])], no_wir_location());
    state.block = finish_block;
    return true;
}

func wir_print_spread(
    ref state: WirFunctionLowering,
    ref types: WirTypeMap,
    ref source: Compiler,
    ref program: WirModule,
    item: WirPrintSource,
    separator: WirExpr,
    printed_slot: WirValueID
) -> Bool {
    let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
    let index_slot: WirValueID = wir_stack_alloc(ref program, state.entry, size_type, "print.index", no_wir_location());
    wir_store(ref program, state.block, wir_const_int(ref program, size_type, UInt128(0U)), index_slot, no_wir_location());
    let condition: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "print.spread.cond."), []);
    let body: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "print.spread.body."), []);
    let finish: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "print.spread.end."), []);
    wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(condition, [])], no_wir_location());

    state.block = condition;
    let index: WirValueID = wir_load(ref program, state.block, index_slot, "", no_wir_location());
    let more: WirValueID = wir_binary(ref program, state.block, WirOpcode.UnsignedLess, program.bool_type, index, item.length, "", no_wir_location());
    wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [more], [wir_edge(body, []), wir_edge(finish, [])], no_wir_location());

    state.block = body;
    let value: WirValueID = wir_load(ref program, state.block, wir_index_address(ref program, state.block, item.data, index, "", no_wir_location()), "", no_wir_location());
    if (!wir_print_next(ref state, ref types, ref source, ref program, WirExpr(value=value, source_type=item.element_type), separator, printed_slot)) {
        return false;
    }
    let next: WirValueID = wir_binary(ref program, state.block, WirOpcode.Add, size_type, index, wir_const_int(ref program, size_type, UInt128(1U)), "", no_wir_location());
    wir_store(ref program, state.block, next, index_slot, no_wir_location());
    wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(condition, [])], no_wir_location());
    state.block = finish;
    return true;
}

func wir_lower_print_call(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, call: CallNode) -> WirExpr {
    let owned_start: Int = state.owned_values.length();
    let values: Vector(WirPrintSource) = [];
    let separator: WirExpr = WirExpr(value=wir_lower_string_constant(ref types, ref program, " "), source_type=TYPE_STRING);
    let ending: WirExpr = WirExpr(value=wir_lower_string_constant(ref types, ref program, "\n"), source_type=TYPE_STRING);
    let saw_named: Bool = false;
    let has_separator: Bool = false;
    let has_ending: Bool = false;
    let i: Int = 0;
    while (call.args is !null && i < call.args.length()) {
        let argument: ArgNode = call.args[i];
        if (argument.name.length() != 0) {
            saw_named = true;
            if (argument.name != "sep" && argument.name != "end") {
                state.errors.append("Unknown print argument '" + argument.name + "'");
                return wir_no_expr();
            }
            if ((argument.name == "sep" && has_separator) || (argument.name == "end" && has_ending)) {
                state.errors.append("Print argument '" + argument.name + "' is specified more than once");
                return wir_no_expr();
            }
            let text: WirExpr = wir_lower_expected_expr(ref state, ref types, ref source, ref program, argument.val, TYPE_STRING);
            if (text.value == NO_WIR_VALUE) {
                return wir_no_expr();
            }
            text = wir_cast_expr(ref state, ref types, ref source, ref program, text, TYPE_STRING, true, no_position());
            if (text.value == NO_WIR_VALUE) {
                return wir_no_expr();
            }
            if (argument.name == "sep") {
                separator = text;
                has_separator = true;
            } else {
                ending = text;
                has_ending = true;
            }
            i++;
            continue;
        }
        if saw_named {
            state.errors.append("Positional print argument follows a named argument");
            return wir_no_expr();
        }
        if (argument.is_spread) {
            let container_type: Int = get_repr_type(ref source, wir_argument_type(ref state, ref source, argument.val));
            let array: Optional(ArrayInfo) = source.array_info_map.lookup(container_type);
            let vector: Optional(SymbolInfo) = source.vector_base_map.lookup(container_type);
            let element_type: Int = TYPE_POISON;
            if ((array is !null)) { element_type = array.base_type; }
            else if ((vector is !null)) { element_type = vector.type; }
            if (element_type == TYPE_POISON) {
                state.errors.append("Only an Array or Vector can be expanded through print");
                return wir_no_expr();
            }
            let expanded: WirVariadicSource = wir_lower_variadic_source(ref state, ref types, ref source, ref program, argument, element_type);
            if (expanded.value.value == NO_WIR_VALUE) { return wir_no_expr(); }
            values.append(WirPrintSource(value=expanded.value, spread=true, length=expanded.length, data=expanded.data, element_type=element_type));
        } else {
            let value: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, argument.val);
            if (value.value == NO_WIR_VALUE) {
                return wir_no_expr();
            }
            if (is_union_type(ref source, get_repr_type(ref source, value.source_type))) {
                throw_type_error(call.pos, "Type " + get_type_name(ref source, value.source_type) + " cannot be printed.");
                return wir_no_expr();
            }
            values.append(WirPrintSource(value=value, spread=false, length=NO_WIR_VALUE, data=NO_WIR_VALUE, element_type=value.source_type));
        }
        i++;
    }

    let printed_slot: WirValueID = wir_stack_alloc(ref program, state.entry, program.bool_type, "print.wrote", no_wir_location());
    wir_store(ref program, state.block, wir_const_bool(ref program, false), printed_slot, no_wir_location());
    i = 0;
    while (i < values.length()) {
        let item: WirPrintSource = values[i];
        if (item.spread) {
            if (!wir_print_spread(ref state, ref types, ref source, ref program, item, separator, printed_slot)) {
                return wir_no_expr();
            }
        } else if (!wir_print_next(ref state, ref types, ref source, ref program, item.value, separator, printed_slot)) {
            return wir_no_expr();
        }
        i++;
    }
    if (!wir_print_value(ref state, ref types, ref source, ref program, ending)) {
        return wir_no_expr();
    }
    wir_cleanup_temporaries(ref state, ref types, ref source, ref program, owned_start);
    return WirExpr(value=NO_WIR_VALUE, source_type=TYPE_VOID);
}

func wir_apply_flow_guard(ref state: WirFunctionLowering, ref source: Compiler, condition: NodeID, truth: Bool) -> Void {
    if (!flow_has_guard(ref source, condition)) { return; }
    let guards: Vector(FlowGuard) = [];
    flow_guards(ref source, condition, truth, guards);
    let i = 0;
    while (i < guards.length()) {
        let guard = guards[i];
        let old_skip = source.flow_skip;
        source.flow_skip = guard.target;
        let original = wir_lvalue_type(ref state, ref source, guard.target);
        source.flow_skip = old_skip;
        let path = format_ast_path(ref source, guard.target);
        let root = expr_root_name(ref source, guard.target);
        let local = wir_local_index(ref state, root);
        let unstable = flow_has_field(path) || local < 0;
        if (local >= 0) { unstable = unstable || state.bindings[local].is_reference; }
        unstable = unstable || flow_is_exposed(ref source, path);
        if (!unstable || !flow_has_call(ref source, condition)) {
            flow_record(ref source, guard.target, original, guard.present, unstable);
        }
        i++;
    }
}

func wir_lower_binary_expr(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: NodeID) -> WirExpr {
// binary trees recurse through a small frame, long logical chains otherwise keep the full expression frame on the stack
    let binary: BinOpNode = get_binop_node(ref source.arena, node);
    if (binary.op_tok.type == TOK_AND || binary.op_tok.type == TOK_OR) {
        let left: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, binary.left);
        if (left.value == NO_WIR_VALUE) {
            return wir_no_expr();
        }
        if (left.source_type != TYPE_BOOL) {
            state.errors.append("logical operator reached WIR lowering with a non-Bool left operand");
            return wir_no_expr();
        }

        let right_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "logic.rhs."), []);
        let merge_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "logic.end."), [wir_param("value", program.bool_type)]);
        let short_value: WirValueID = wir_const_bool(ref program, binary.op_tok.type == TOK_OR);
        if (binary.op_tok.type == TOK_AND) {
            wir_append(
                ref program,
                state.block,
                WirOpcode.Branch,
                program.void_type,
                [left.value],
                [wir_edge(right_block, []), wir_edge(merge_block, [short_value])],
                no_wir_location()
            );
        } else {
            wir_append(
                ref program,
                state.block,
                WirOpcode.Branch,
                program.void_type,
                [left.value],
                [wir_edge(merge_block, [short_value]), wir_edge(right_block, [])],
                no_wir_location()
            );
        }

        state.block = right_block;
        let before_rhs = flow_copy(source.flow_types);
        wir_apply_flow_guard(ref state, ref source, binary.left, binary.op_tok.type == TOK_AND);
        let right_owned_start: Int = state.owned_values.length();
        let right: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, binary.right);
        source.flow_types = flow_intersect(before_rhs, source.flow_types);
        if (right.value == NO_WIR_VALUE) { return wir_no_expr(); }
        if (right.source_type != TYPE_BOOL) {
            state.errors.append("logical operator reached WIR lowering with a non-Bool right operand");
            return wir_no_expr();
        }
        wir_cleanup_temporaries(ref state, ref types, ref source, ref program, right_owned_start);
        wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(merge_block, [right.value])], no_wir_location());
        state.block = merge_block;
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(merge_block))];
        return WirExpr(value=block.parameters[0], source_type=TYPE_BOOL);
    }

    let owned_start: Int = state.owned_values.length();
    let left: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, binary.left);
    let right: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, binary.right);
    if (left.value == NO_WIR_VALUE || right.value == NO_WIR_VALUE) {
        return wir_no_expr();
    }
    let left_repr: Int = get_repr_type(ref source, left.source_type);
    let right_repr: Int = get_repr_type(ref source, right.source_type);
    if (is_union_type(ref source, left_repr) || is_union_type(ref source, right_repr)) {
        throw_type_error(binary.pos, "Invalid types for binary operator.");
        return wir_no_expr();
    }
    if (binary.op_tok.type == TOK_PLUS && (left_repr == TYPE_STRING || right_repr == TYPE_STRING)) {
        let result_type: Int = TYPE_STRING;
        if (left.source_type == right.source_type && left_repr == TYPE_STRING) {
            result_type = left.source_type;
        }
        let left_stringable: Bool = left_repr == TYPE_STRING || left_repr == TYPE_NULL || left_repr == TYPE_NULLPTR || is_primitive_type(left_repr);
        let right_stringable: Bool = right_repr == TYPE_STRING || right_repr == TYPE_NULL || right_repr == TYPE_NULLPTR || is_primitive_type(right_repr);
        if (!left_stringable || !right_stringable) {
            let other_type: Int = right.source_type;
            if (left_repr != TYPE_STRING) { other_type = left.source_type; }
            throw_type_error(binary.pos, "Cannot concatenate String and " + get_type_name(ref source, other_type));
            return wir_no_expr();
        }
        if (left_repr != TYPE_STRING) {
            left = wir_convert_to_string(ref state, ref types, ref source, ref program, left);
        }
        if (right_repr != TYPE_STRING) {
            right = wir_convert_to_string(ref state, ref types, ref source, ref program, right);
        }
        if (left.value == NO_WIR_VALUE || right.value == NO_WIR_VALUE) {
            return wir_no_expr();
        }
        let target: Optional(FuncInfo) = wir_compiler_link_function(ref source, "string_concat");
        if (!(target is !null)) {
            state.errors.append("String concatenation runtime function is unavailable during WIR lowering");
            return wir_no_expr();
        }
        let function_id: WirFuncID = wir_find_function(program, target.name);
        if (function_id == NO_WIR_FUNC) {
            function_id = wir_lower_function_decl(ref types, ref source, ref program, target);
        }
        if (function_id == NO_WIR_FUNC) { return wir_no_expr(); }
        let result: WirValueID = wir_call(ref program, state.block, wir_function_value(ref program, function_id), [left.value, right.value], "", no_wir_location());
        wir_cleanup_temporaries(ref state, ref types, ref source, ref program, owned_start);
        wir_track_owned(ref state, result, TYPE_STRING);
        return WirExpr(value=result, source_type=result_type);
    }
    if ((binary.op_tok.type == TOK_EE || binary.op_tok.type == TOK_NE) && left_repr == TYPE_STRING && right_repr == TYPE_STRING) {
        let result: WirExpr = wir_compare_strings(ref state, ref types, ref source, ref program, left, right, binary.op_tok.type);
        wir_cleanup_temporaries(ref state, ref types, ref source, ref program, owned_start);
        return result;
    }
    if ((left.source_type == TYPE_ANY_ERROR || right.source_type == TYPE_ANY_ERROR) &&
        (binary.op_tok.type == TOK_EE || binary.op_tok.type == TOK_NE)) {
        let result: WirExpr = wir_compare_errors(ref state, ref types, ref source, ref program, left, right, binary.op_tok.type);
        if (result.value != NO_WIR_VALUE) { return result; }
    }
    if ((binary.op_tok.type == TOK_EE || binary.op_tok.type == TOK_NE) &&
        wir_is_enum_type(ref source, left.source_type) && wir_is_enum_type(ref source, right.source_type)) {
        let compatible: Bool = left.source_type == right.source_type ||
                               left.source_type == TYPE_GENERIC_ENUM || right.source_type == TYPE_GENERIC_ENUM;
        if (!compatible) {
            state.errors.append("different enum types reached WIR comparison lowering");
            return wir_no_expr();
        }
        let opcode: WirOpcode = WirOpcode.Equal;
        if (binary.op_tok.type == TOK_NE) { opcode = WirOpcode.NotEqual; }
        return WirExpr(value=wir_binary(ref program, state.block, opcode, program.bool_type, left.value, right.value, "", no_wir_location()), source_type=TYPE_BOOL);
    }
    let protocol_comparison: WirMemberCall = wir_lower_protocol_comparison(ref state, ref types, ref source, ref program, left, right, binary.op_tok.type);
    if (protocol_comparison.handled) {
        wir_cleanup_temporaries(ref state, ref types, ref source, ref program, owned_start);
        return protocol_comparison.value;
    }
    if (binary.op_tok.type == TOK_POW) {
        if (!wir_source_numeric(left_repr) || !wir_source_numeric(right_repr)) {
            throw_type_error(binary.pos, "Operator '**' requires numeric operands");
            return wir_no_expr();
        }
        left = wir_cast_expr(ref state, ref types, ref source, ref program, left, TYPE_FLOAT, false, no_position());
        right = wir_cast_expr(ref state, ref types, ref source, ref program, right, TYPE_FLOAT, false, no_position());
        if (left.value == NO_WIR_VALUE || right.value == NO_WIR_VALUE) {
            return wir_no_expr();
        }
        let target: Optional(FuncInfo) = wir_compiler_link_function(ref source, "float_pow");
        if (!(target is !null)) {
            state.errors.append("Floating-point exponentiation runtime function is unavailable during WIR lowering");
            return wir_no_expr();
        }
        let meta_target: FuncInfo = target;
        let function_id: WirFuncID = wir_find_function(program, meta_target.name);
        if (function_id == NO_WIR_FUNC) {
            function_id = wir_lower_function_decl(ref types, ref source, ref program, meta_target);
        }
        if (function_id == NO_WIR_FUNC) {
            return wir_no_expr();
        }
        let result: WirValueID = wir_call(ref program, state.block, wir_function_value(ref program, function_id), [left.value, right.value], "", no_wir_location());
        return WirExpr(value=result, source_type=TYPE_FLOAT);
    }
    let common_type: Int = wir_binary_type(ref state, ref source, left, right, binary.left, binary.right);
    if (common_type == TYPE_POISON) {
        if (state.errors.length() == 0) {
            state.errors.append("binary operands reached WIR lowering with incompatible types");
        }
        return wir_no_expr();
    }
    if ((binary.op_tok.type == TOK_LSHIFT || binary.op_tok.type == TOK_RSHIFT) && is_unsuffix_int_literal(ref source, binary.right)) {
        let bits: Int = get_type_bitwidth(get_repr_type(ref source, common_type));
        let amount: Long = eval_const_long(ref source, binary.right, binary.pos);
        if (amount < 0L || amount >= Long(bits)) {
            throw_overflow_error(binary.pos, "Shift count must be between 0 and " + (bits - 1));
            return wir_no_expr();
        }
    }
    left = wir_cast_expr(ref state, ref types, ref source, ref program, left, common_type, false, no_position());
    right = wir_cast_expr(ref state, ref types, ref source, ref program, right, common_type, false, no_position());
    if (left.value == NO_WIR_VALUE || right.value == NO_WIR_VALUE) {
        return wir_no_expr();
    }

    let common_repr: Int = get_repr_type(ref source, common_type);
    if ((binary.op_tok.type == TOK_DIV || binary.op_tok.type == TOK_MOD) && is_integer_type(common_repr)) {
        let integer_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, common_type);
        let zero: WirValueID = wir_const_int(ref program, integer_type, UInt128(0U));
        let nonzero: WirValueID = wir_binary(ref program, state.block, WirOpcode.NotEqual, program.bool_type, right.value, zero, "", no_wir_location());
        wir_guard_runtime(ref state, ref program, nonzero, "__wl_fail_division");
        if (is_signed_integer(common_repr)) {
            wir_guard_signed_div(ref state, ref program, left.value, right.value, integer_type);
        }
    }

    let runtime_arithmetic: Bool = ((common_repr == TYPE_FLOAT || common_repr == TYPE_FLOAT32) && binary.op_tok.type == TOK_MOD) ||
                                   ((common_repr == TYPE_INT128 || common_repr == TYPE_UINT128) &&
                                    (binary.op_tok.type == TOK_DIV || binary.op_tok.type == TOK_MOD));
    if runtime_arithmetic {
        return wir_lower_runtime_arithmetic(ref state, ref types, ref source, ref program, left, right, common_type, binary.op_tok.type);
    }

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

func wir_lower_expr(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: NodeID) -> WirExpr {
    if (has_node(node) && node_tag(node) == NODE_REF) { flow_expose(ref source, get_ref_node(ref source.arena, node).node); }
    let member = flow_type(ref source, node);
    let result = wir_no_expr();
    if (has_node(node) && node_tag(node) == NODE_BINOP) {
        result = wir_lower_binary_expr(ref state, ref types, ref source, ref program, node);
    } else {
        result = wir_lower_raw_expr(ref state, ref types, ref source, ref program, node);
    }
    if (result.value != NO_WIR_VALUE && member != 0 && is_union_type(ref source, get_repr_type(ref source, result.source_type))) {
        if (member == TYPE_NULL) {
            result = WirExpr(value=wir_null(ref program, wir_opaque_pointer(ref types, ref program)), source_type=TYPE_NULL);
        } else {
            let slot = wir_stack_alloc(ref program, state.entry, wir_value_type(ref program, result.value), "union.read", no_wir_location());
            wir_store(ref program, state.block, result.value, slot, no_wir_location());
            let payload = wir_union_payload(ref state, ref types, ref source, ref program, slot, member);
            result = WirExpr(value=wir_load(ref program, state.block, payload, "", no_wir_location()), source_type=member);
            if (wir_value_needs_drop(ref source, member)) {
                wir_emit_ownership_value(ref state, ref types, ref source, ref program, result.value, member, true);
                wir_track_owned(ref state, result.value, member);
            }
        }
    }
    if (has_node(node) && node_tag(node) == NODE_CALL) { flow_forget(ref source, "", true); }
    return result;
}

func wir_lower_raw_expr(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: NodeID) -> WirExpr {
// source expressions recurse through this dispatch, large handlers own separate stack frames
    if (!has_node(node)) {
        state.errors.append("expression is missing from the resolved AST");
        return wir_no_expr();
    }

    let kind: Int = node_tag(node);
    if (kind == NODE_VAR_ACCESS || kind == NODE_FIELD_ACCESS) {
        let intrinsic_info: Optional(SymbolInfo) = target_intrinsic_symbol(ref source, node);
        if ((intrinsic_info is !null)) {
            let intrinsic: String = intrinsic_info.reg.slice(11, intrinsic_info.reg.length());
            let source_type: Int = intrinsic_info.type;
            let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
            if (type_id == NO_WIR_TYPE) {
                return wir_no_expr();
            }
            return WirExpr(value=wir_const_int(ref program, type_id, UInt128(target_value(intrinsic))), source_type=source_type);
        }
    }
    if (kind == NODE_INT) {
        let literal: IntNode = get_int_node(ref source.arena, node);
        let source_type: Int = get_expr_type(ref source, node);
        let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
        return WirExpr(value=wir_const_int(ref program, type_id, parse_const_uint128(literal.tok.value, literal.pos)), source_type=source_type);
    }
    if (kind == NODE_FLOAT) {
        let literal: FloatNode = get_float_node(ref source.arena, node);
        let source_type: Int = get_expr_type(ref source, node);
        let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
        return WirExpr(value=wir_const_float(ref program, type_id, parse_decimal_float_literal(literal.tok.value)), source_type=source_type);
    }
    if (kind == NODE_CHAR) {
        let literal: CharNode = get_char_node(ref source.arena, node);
        let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, TYPE_CHAR);
        return WirExpr(value=wir_const_int(ref program, type_id, UInt128(string_to_int(literal.tok.value, literal.pos))), source_type=TYPE_CHAR);
    }
    if (kind == NODE_BOOL) {
        let literal: BooleanNode = get_bool_node(ref source.arena, node);
        return WirExpr(value=wir_const_bool(ref program, literal.value != 0), source_type=TYPE_BOOL);
    }
    if (kind == NODE_STRING) {
        let literal: StringNode = get_string_node(ref source.arena, node);
        return WirExpr(value=wir_lower_string_constant(ref types, ref program, literal.tok.value), source_type=TYPE_STRING);
    }
    if (kind == NODE_NULL || kind == NODE_NULLPTR) {
        let type_id: WirTypeID = wir_opaque_pointer(ref types, ref program);
        let source_type: Int = TYPE_NULL;
        if (kind == NODE_NULLPTR) { source_type = TYPE_NULLPTR; }
        return WirExpr(value=wir_null(ref program, type_id), source_type=source_type);
    }
    if (kind == NODE_TYPE_LAYOUT) {
        return wir_expr_type_layout(ref state, ref types, ref source, ref program, node);
    }
    if (kind == NODE_MAP_LIT) {
        return wir_lower_map_literal(ref state, ref types, ref source, ref program, node, get_expr_type(ref source, node));
    }
    if (kind == NODE_GENERIC_TYPE) {
        let generic: GenericTypeNode = get_generic_type_node(ref source.arena, node);
        if (has_node(generic.base_type) && node_tag(generic.base_type) == NODE_FIELD_ACCESS) {
            let bound_method: WirMemberCall = wir_lower_generic_method_value(ref state, ref types, ref source, ref program, generic);
            if (bound_method.handled) { return bound_method.value; }
        }
        let empty_args: Vector(ArgNode) = [];
        let call: CallNode = CallNode(type=NODE_CALL, callee=generic.base_type, args=empty_args, type_args=generic.type_args, pos=generic.pos, preserve_fallible=false);
        let info: Optional(FuncInfo) = wir_generic_call_function(ref state, ref source, call);
        if (!(info is !null)) {
            state.errors.append("Generic function value could not be instantiated during WIR lowering");
            return wir_no_expr();
        }
        return wir_lower_function_value(ref state, ref types, ref source, ref program, info);
    }
    if (kind == NODE_VAR_ACCESS) {
        let access: VarAccessNode = get_var_access_node(ref source.arena, node);
        if (!wir_name_is_value(ref state, ref source, access.name_tok.value)) {
            let info: Optional(FuncInfo) = wir_source_function(ref source, access.name_tok.value);
            if ((info is !null)) {
                return wir_lower_function_value(ref state, ref types, ref source, ref program, info);
            }
        }
        let address: WirExpr = wir_lower_lvalue(ref state, ref types, ref source, ref program, node);
        if (address.value == NO_WIR_VALUE) { return wir_no_expr(); }
        return WirExpr(value=wir_load(ref program, state.block, address.value, "", no_wir_location()), source_type=address.source_type);
    }
    if (kind == NODE_FIELD_ACCESS) {
        return wir_expr_field_access(ref state, ref types, ref source, ref program, node);
    }
    if (kind == NODE_REF) {
        let reference: RefNode = get_ref_node(ref source.arena, node);
        if (has_node(reference.node) && node_tag(reference.node) == NODE_SLICE_ACCESS) {
            return wir_lower_slice_access(ref state, ref types, ref source, ref program, get_slice_access_node(ref source.arena, reference.node), true);
        }
        if (wir_lvalue_const(ref state, ref source, reference.node)) {
            state.errors.append("const value reached WIR lowering as a mutable reference");
            return wir_no_expr();
        }
        let address: WirExpr = wir_lower_lvalue(ref state, ref types, ref source, ref program, reference.node);
        if (address.value == NO_WIR_VALUE) {
            return wir_no_expr();
        }
        return WirExpr(value=address.value, source_type=get_ptr_type_id(ref source, address.source_type));
    }
    if (kind == NODE_DEREF) {
        return wir_expr_deref(ref state, ref types, ref source, ref program, node);
    }
    if (kind == NODE_IS || kind == NODE_IS_NOT) {
        let identity: BinOpNode = get_binop_node(ref source.arena, node);
        let old_skip = source.flow_skip;
        source.flow_skip = identity.left;
        let left: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, identity.left);
        source.flow_skip = identity.right;
        let right: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, identity.right);
        source.flow_skip = old_skip;
        if (left.value == NO_WIR_VALUE || right.value == NO_WIR_VALUE) {
            return wir_no_expr();
        }
        let left_union: Bool = is_union_type(ref source, get_repr_type(ref source, left.source_type));
        let right_union: Bool = is_union_type(ref source, get_repr_type(ref source, right.source_type));
        if (left_union || right_union) {
            let value: WirExpr = left;
            if (right_union && left.source_type == TYPE_NULL) { value = right; }
            else if (!left_union || right.source_type != TYPE_NULL) {
                throw_type_error(identity.pos, "Union identity comparisons require a Null operand.");
                return wir_no_expr();
            }
            let member: Int = union_member_index(ref source, get_repr_type(ref source, value.source_type), TYPE_NULL);
            if (member < 0) {
                return WirExpr(value=wir_const_bool(ref program, kind == NODE_IS_NOT), source_type=TYPE_BOOL);
            }
            let tag: WirValueID = wir_field(ref program, state.block, value.value, 0, "", no_wir_location());
            let tag_type: WirTypeID = wir_value_type(ref program, tag);
            let opcode: WirOpcode = WirOpcode.Equal;
            if (kind == NODE_IS_NOT) { opcode = WirOpcode.NotEqual; }
            let result: WirValueID = wir_binary(ref program, state.block, opcode, program.bool_type, tag,
                wir_const_int(ref program, tag_type, UInt128(UInt32(member))), "", no_wir_location());
            return WirExpr(value=result, source_type=TYPE_BOOL);
        }
        left = wir_identity_value(ref state, ref types, ref source, ref program, left);
        right = wir_identity_value(ref state, ref types, ref source, ref program, right);
        if (left.value == NO_WIR_VALUE || right.value == NO_WIR_VALUE) { return wir_no_expr(); }
        let opcode: WirOpcode = WirOpcode.Equal;
        if (kind == NODE_IS_NOT) { opcode = WirOpcode.NotEqual; }
        return WirExpr(value=wir_binary(ref program, state.block, opcode, program.bool_type, left.value, right.value, "", no_wir_location()), source_type=TYPE_BOOL);
    }
    if (kind == NODE_INDEX_ACCESS) {
        return wir_lower_index_expr(ref state, ref types, ref source, ref program, get_index_access_node(ref source.arena, node), false);
    }
    if (kind == NODE_SLICE_ACCESS) {
        return wir_lower_slice_access(ref state, ref types, ref source, ref program, get_slice_access_node(ref source.arena, node), false);
    }
    if (kind == NODE_UNARYOP) {
        return wir_expr_unaryop(ref state, ref types, ref source, ref program, node);
    }
    if (kind == NODE_POSTFIX) {
        return wir_expr_postfix(ref state, ref types, ref source, ref program, node);
    }
    if (kind == NODE_TRY_UNWRAP) {
        return wir_lower_try_unwrap(ref state, ref types, ref source, ref program, get_try_unwrap_node(ref source.arena, node));
    }
    if (kind == NODE_CALL) {
        return wir_expr_call(ref state, ref types, ref source, ref program, node);
    }

    state.errors.append("AST node kind " + kind + " is not lowered to WIR yet");
    return wir_no_expr();
}

func wir_expr_type_layout(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: NodeID) -> WirExpr {
    let query: TypeLayoutNode = get_type_layout_node(ref source.arena, node);
    let source_type: Int = resolve_type(ref source, query.type_node);
    if (!check_layout_type(ref source, source_type, query.is_align, query.pos)) {
        return wir_no_expr();
    }
    let type_id: WirTypeID = NO_WIR_TYPE;
    let union: Bool = is_union_type(ref source, get_repr_type(ref source, source_type));
    if (union) {
        type_id = wir_union_storage(ref types, ref source, ref program, get_repr_type(ref source, source_type));
    } else {
        type_id = wir_lower_source_type(ref types, ref source, ref program, source_type);
    }
    if (type_id == NO_WIR_TYPE) { return wir_no_expr(); }
    let layout: WirTypeLayout = wir_lowering_layout(ref types, program, type_id);
    if (!layout.valid) {
        state.errors.append("type layout is unavailable during WIR lowering");
        return wir_no_expr();
    }
    let value: UInt128 = UInt128(layout.size);
    if (query.is_align) { value = UInt128(layout.alignment); }
    let result_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, TYPE_UINTSIZE);
    return WirExpr(value=wir_const_int(ref program, result_type, value), source_type=TYPE_UINTSIZE);
}

func wir_expr_field_access(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: NodeID) -> WirExpr {
    let access: FieldAccessNode = get_field_access_node(ref source.arena, node);
    let enum_member: Optional(WirEnumValue) = wir_enum_member(ref types, ref source, node, access);
    if (enum_member is !null) {
        let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, enum_member.source_type);
        if (type_id == NO_WIR_TYPE) {
            return wir_no_expr();
        }
        return WirExpr(value=wir_const_int(ref program, type_id, UInt128(enum_member.value)), source_type=enum_member.source_type);
    }
    let unknown_root: String = wir_unknown_path_root(ref state, ref source, node);
    if (unknown_root.length() != 0) {
        throw_name_error(access.pos, "Undefined variable or function '" + unknown_root + "'.");
        return wir_no_expr();
    }
    let enum_owner: Optional(StructInfo) = wir_struct_constructor(ref source, access.obj);
    if ((enum_owner is !null) && enum_owner.is_enum && !(find_field(enum_owner, access.field_name) is !null)) {
        throw_name_error(access.pos, "Enum '" + format_ast_path(ref source, access.obj) + "' has no member '" + access.field_name + "'.");
        return wir_no_expr();
    }
    let global: WirSourceGlobal = wir_direct_global(ref state, ref source, node);
    if (has_wir_source_global(global)) {
        let global_id: WirGlobalID = wir_find_global(program, global.name);
        if (global_id == NO_WIR_GLOBAL) {
            state.errors.append("global '" + global.name + "' was not declared before WIR lowering");
            return wir_no_expr();
        }
        return WirExpr(value=wir_load(ref program, state.block, wir_global_value(ref program, global_id), "", no_wir_location()), source_type=global.source_type);
    }
    let module_symbol: String = wir_module_symbol(ref state, ref source, node);
    if (module_symbol.length() != 0) {
        throw_name_error(access.pos, "Undefined module variable '" + module_symbol + "'.");
        return wir_no_expr();
    }
    let bound_method: WirMemberCall = wir_lower_bound_method(ref state, ref types, ref source, ref program, access);
    if (bound_method.handled) { return bound_method.value; }
    let addressable: Bool = wir_addressable_node(ref source, access.obj);
    let object: WirExpr = wir_no_expr();
    let object_source_type: Int = TYPE_POISON;
    if addressable {
        object_source_type = wir_lvalue_type(ref state, ref source, access.obj);
    } else {
        object = wir_lower_expr(ref state, ref types, ref source, ref program, access.obj);
        if (object.value == NO_WIR_VALUE) {
            return wir_no_expr();
        }
        object_source_type = object.source_type;
    }
    let owner_type: Int = get_repr_type(ref source, object_source_type);
    if (is_union_type(ref source, owner_type)) {
        throw_type_error(access.pos, "Cannot access a field of " + get_type_name(ref source, object_source_type) + " before narrowing.");
        return wir_no_expr();
    }
    let indirect: Bool = false;
    let pointer: Optional(SymbolInfo) = source.ptr_base_map.lookup(owner_type);
    if ((pointer is !null)) {
        owner_type = get_repr_type(ref source, pointer.type);
        indirect = true;
    }
    let owner: Optional(StructInfo) = source.struct_id_map.lookup(owner_type);
    let field: Optional(FieldInfo) = find_field(owner, access.field_name);
    if (!(owner is !null) || owner.is_interface || owner.is_enum || !(field is !null)) {
        let owner_name: String = "type " + owner_type;
        if ((owner is !null)) { owner_name = "'" + owner.name + "'"; }
        state.errors.append("field '" + access.field_name + "' is not available on " + owner_name + " during WIR lowering");
        return wir_no_expr();
    }
    let meta_owner: StructInfo = owner;
    if (!meta_owner.is_class && !indirect && addressable) {
        let address: WirExpr = wir_lower_field_lvalue(ref state, ref types, ref source, ref program, access.obj, access.field_name);
        if (address.value == NO_WIR_VALUE) { return wir_no_expr(); }
        return WirExpr(value=wir_load(ref program, state.block, address.value, "", no_wir_location()), source_type=field.type);
    }
    if (object.value == NO_WIR_VALUE) {
        object = wir_lower_expr(ref state, ref types, ref source, ref program, access.obj);
        if (object.value == NO_WIR_VALUE) {
            return wir_no_expr();
        }
    }
    if (meta_owner.is_class || indirect) {
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [object.value], [], no_wir_location());
        let address: WirValueID = wir_field_address(ref program, state.block, object.value, field.offset, "", no_wir_location());
        return WirExpr(value=wir_load(ref program, state.block, address, "", no_wir_location()), source_type=field.type);
    }
    return WirExpr(value=wir_field(ref program, state.block, object.value, field.offset, "", no_wir_location()), source_type=field.type);
}

func wir_expr_deref(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: NodeID) -> WirExpr {
    let dereference: DerefNode = get_deref_node(ref source.arena, node);
    let value: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, dereference.node);
    if (value.value == NO_WIR_VALUE) {
        return wir_no_expr();
    }
    let level: Int = 0;
    while (level < dereference.level) {
        let pointer: Optional(SymbolInfo) = source.ptr_base_map.lookup(value.source_type);
        if (!(pointer is !null) || pointer.type == TYPE_VOID) {
            throw_type_error(dereference.pos, "Attempt to dereference non-pointer.");
            return wir_no_expr();
        }
        let meta_pointer: SymbolInfo = pointer;
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [value.value], [], no_wir_location());
        value = WirExpr(value=wir_load(ref program, state.block, value.value, "", no_wir_location()), source_type=meta_pointer.type);
        level++;
    }
    return value;
}

func wir_expr_unaryop(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: NodeID) -> WirExpr {
    let unary: UnaryOpNode = get_unary_node(ref source.arena, node);
    let operand: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, unary.node);
    if (operand.value == NO_WIR_VALUE) { return wir_no_expr(); }

    if (unary.op_tok.type == TOK_PLUS) {
        if (!wir_source_numeric(get_repr_type(ref source, operand.source_type))) {
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
    if (opcode == WirOpcode.Invalid) {
        return wir_no_expr();
    }

    let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, operand.source_type);
    return WirExpr(value=wir_unary(ref program, state.block, opcode, type_id, operand.value, "", no_wir_location()), source_type=operand.source_type);
}

func wir_expr_postfix(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: NodeID) -> WirExpr {
    let postfix: PostfixOpNode = get_postfix_node(ref source.arena, node);
    if (!has_node(postfix.node)) {
        state.errors.append("postfix operator has no target in WIR lowering");
        return wir_no_expr();
    }
    if (wir_lvalue_const(ref state, ref source, postfix.node)) {
        let name: String = expr_root_name(ref source, postfix.node);
        throw_type_error(postfix.pos, "Cannot modify constant variable '" + name + "'.");
        return wir_no_expr();
    }
    let address: WirExpr = wir_lower_lvalue(ref state, ref types, ref source, ref program, postfix.node);
    if (address.value == NO_WIR_VALUE) {
        return wir_no_expr();
    }
    if (!wir_source_numeric(get_repr_type(ref source, address.source_type))) {
        state.errors.append("postfix operator reached WIR lowering with a non-numeric operand");
        return wir_no_expr();
    }

    let old_value: WirValueID = wir_load(ref program, state.block, address.value, "", no_wir_location());
    let one: WirValueID = wir_one(ref types, ref source, ref program, address.source_type);
    let opcode: WirOpcode = WirOpcode.Add;

    if (postfix.op_tok.type == TOK_DEC) { opcode = WirOpcode.Subtract; }

    let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, address.source_type);
    let new_value: WirValueID = wir_binary(ref program, state.block, opcode, type_id, old_value, one, "", no_wir_location());
    wir_store(ref program, state.block, new_value, address.value, no_wir_location());
    return WirExpr(value=old_value, source_type=address.source_type);
}

func wir_expr_call(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: NodeID) -> WirExpr {
    let call: CallNode = get_call_node(ref source.arena, node);
    let cast_target: Int = wir_cast_target(ref source, call.callee);
    if (cast_target != 0) {
        let owned_start: Int = state.owned_values.length();
        let argument_count: Int = 0;
        if (call.args is !null) { argument_count = call.args.length(); }
        if (argument_count != 1) {
            state.errors.append("type conversion reached WIR lowering with the wrong argument count");
            return wir_no_expr();
        }
        let argument: ArgNode = call.args[0];
        if ((argument.name.length() != 0) || argument.is_spread) {
            state.errors.append("named or spread argument reached WIR type conversion");
            return wir_no_expr();
        }
        if (!validate_explicit_literal_cast(ref source, argument.val, cast_target, call.pos)) {
            return wir_no_expr();
        }
        let value: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, argument.val);
        if (value.value == NO_WIR_VALUE) {
            return wir_no_expr();
        }
        let source_info: Optional(StructInfo) = null;
        source_info = source.struct_id_map.lookup(get_repr_type(ref source, value.source_type));
        let conversion: Optional(FuncInfo) = null;
        if ((source_info is !null) && source_info.is_class) {
            conversion = find_class_conversion(source_info, cast_target);
        }
        if (conversion is !null) {
            let function_id: WirFuncID = wir_find_function(program, conversion.name);
            if (function_id == NO_WIR_FUNC) {
                function_id = wir_lower_function_decl(ref types, ref source, ref program, conversion);
            }
            if (function_id == NO_WIR_FUNC) {
                return wir_no_expr();
            }
            let receiver: WirExpr = value;
            if (conversion.arg_types is !null && conversion.arg_types.length() != 0) {
                let self_parameter: TypeListNode = conversion.arg_types[0];
                receiver = wir_cast_expr(ref state, ref types, ref source, ref program, value, self_parameter.type, true, no_position());
                if (receiver.value == NO_WIR_VALUE) {
                    return wir_no_expr();
                }
            }
            let result: WirValueID = wir_call(ref program, state.block, wir_function_value(ref program, function_id), [receiver.value], "", no_wir_location());
            wir_cleanup_temporaries(ref state, ref types, ref source, ref program, owned_start);
            if (wir_value_needs_drop(ref source, conversion.ret_type)) {
                wir_track_owned(ref state, result, conversion.ret_type);
            }
            let converted: WirExpr = WirExpr(value=result, source_type=conversion.ret_type);
            if (is_fallible_type(ref source, conversion.ret_type) && !call.preserve_fallible) {
                return wir_unwrap_conversion(ref state, ref types, ref source, ref program, converted, cast_target);
            }
            return converted;
        }
        if (cast_target == TYPE_STRING) {
            return wir_convert_to_string(ref state, ref types, ref source, ref program, value);
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
        return wir_cast_expr(ref state, ref types, ref source, ref program, value, cast_target, false, no_position());
    }
    let super_call: WirMemberCall = wir_lower_super_call(ref state, ref types, ref source, ref program, call);
    if (super_call.handled) { return super_call.value; }
    let info: Optional(FuncInfo) = wir_direct_function(ref state, ref source, call.callee);
    if (!(info is !null)) { info = wir_generic_call_function(ref state, ref source, call); }
    if ((info is !null) && (info.compiler_link_name == "dict_key_hash" || info.compiler_link_name == "dict_keys_equal")) {
        return wir_lower_dict_intrinsic(ref state, ref types, ref source, ref program, call, info);
    }
    if ((info is !null) && !wir_check_fallible_call(ref source, call, info.ret_type, info.base_name)) {
        return wir_no_expr();
    }
    if ((info is !null) && (info.ann_flags & FLAG_ANN_INTRINSIC) != 0) {
        if (info.base_name == "print") {
            return wir_lower_print_call(ref state, ref types, ref source, ref program, call);
        }
        state.errors.append("Compiler intrinsic '" + info.base_name + "' is not lowered to WIR");
        return wir_no_expr();
    }
    let direct_arguments: BoundCallArgs = BoundCallArgs(valid=false, ordered=[], variadic=[]);
    if ((info is !null) && !info.is_varargs) {
        direct_arguments = bind_native_args(call.args, info, 0, call.pos);
        if (!has_bound_args(direct_arguments)) {
            state.errors.append("Arguments to '" + info.name + "' could not be bound before WIR lowering");
            return wir_no_expr();
        }
    }
    let source_parameter_types: Vector(Int) = [];
    let source_parameter_modes: Vector(Int) = [];
    if ((info is !null)) {
        let meta_info: FuncInfo = info;
        let parameter_index: Int = 0;
        while (meta_info.arg_types is !null && parameter_index < meta_info.arg_types.length()) {
            let parameter: TypeListNode = meta_info.arg_types[parameter_index];
            source_parameter_types.append(parameter.type);
            source_parameter_modes.append(parameter.pass_mode);
            parameter_index++;
        }
    }
    if (!(info is !null)) {
        if (node_tag(call.callee) == NODE_FIELD_ACCESS) {
            let access: FieldAccessNode = get_field_access_node(ref source.arena, call.callee);
            let length_call: WirMemberCall = wir_lower_length_call(ref state, ref types, ref source, ref program, call, access);
            if (length_call.handled) { return length_call.value; }
            let string_call: WirMemberCall = wir_lower_string_call(ref state, ref types, ref source, ref program, call, access);
            if (string_call.handled) { return string_call.value; }
            let vector_append: WirMemberCall = wir_lower_vector_append(ref state, ref types, ref source, ref program, call, access);
            if (vector_append.handled) { return vector_append.value; }
            let vector_drop: WirMemberCall = wir_lower_vector_drop(ref state, ref types, ref source, ref program, call, access);
            if (vector_drop.handled) { return vector_drop.value; }
            let protocol_call: WirMemberCall = wir_lower_builtin_protocol_call(ref state, ref types, ref source, ref program, call, access);
            if (protocol_call.handled) { return protocol_call.value; }
        }
        let generic_method_call: WirMemberCall = wir_lower_generic_method_call(ref state, ref types, ref source, ref program, call);
        if (generic_method_call.handled) { return generic_method_call.value; }
        let member_call: WirMemberCall = wir_lower_class_call(ref state, ref types, ref source, ref program, call);
        if (member_call.handled) { return member_call.value; }
    }
    let constructor_type = wir_generic_constructor_type(ref state, ref source, call);
    if (constructor_type == TYPE_POISON) { return wir_no_expr(); }
    let constructor: Optional(StructInfo) = null;
    if (constructor_type != 0) { constructor = source.struct_id_map.lookup(constructor_type); }
    else { constructor = wir_struct_constructor(ref source, call.callee); }
    if ((constructor is !null) && !constructor.is_interface && !constructor.is_enum) {
        if (constructor.is_class) {
            return wir_lower_class_constructor(ref state, ref types, ref source, ref program, call, constructor);
        }
        return wir_lower_struct_constructor(ref state, ref types, ref source, ref program, call, constructor);
    }
    if (!(info is !null)) {
        let unknown_root: String = wir_unknown_call_root(ref state, ref source, call.callee);
        if (unknown_root.length() != 0) {
            throw_name_error(call.pos, "Undefined variable or function '" + unknown_root + "'.");
            return wir_no_expr();
        }
        let module_symbol: String = wir_module_symbol(ref state, ref source, call.callee);
        if (module_symbol.length() != 0) {
            throw_name_error(call.pos, "Function '" + module_symbol + "' is not defined.");
            return wir_no_expr();
        }
    }
    let callee_value: WirValueID = NO_WIR_VALUE;
    let signature_info: Optional(SymbolInfo) = null;
    let result_type: Int = TYPE_POISON;
    let callable_name: String = "function value";
    let indirect_call: Bool = false;
    let indirect_source_type: Int = TYPE_POISON;
    if ((info is !null)) {
        let function_id: WirFuncID = wir_find_function(program, info.name);
        if (function_id == NO_WIR_FUNC) {
            function_id = wir_lower_function_decl(ref types, ref source, ref program, info);
        }
        if (function_id == NO_WIR_FUNC) {
            return wir_no_expr();
        }
        callee_value = wir_function_value(ref program, function_id);
        result_type = info.ret_type;
        callable_name = info.name;
    } else {
        let indirect: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, call.callee);
        if (indirect.value == NO_WIR_VALUE) {
            return wir_no_expr();
        }
        signature_info = source.func_ret_map.lookup(indirect.source_type);
        if (!(signature_info is !null)) {
            signature_info = source.method_ret_map.lookup(indirect.source_type);
            if ((signature_info is !null)) { callable_name = "method value"; }
        }
        if (!(signature_info is !null)) {
            state.errors.append("Indirect call target does not have a Function or Method type");
            return wir_no_expr();
        }
        let meta_signature_info: SymbolInfo = signature_info;
        callee_value = indirect.value;
        indirect_call = true;
        indirect_source_type = indirect.source_type;
        source_parameter_types = [];
        source_parameter_modes = [];
        let source_index: Int = 0;
        while (meta_signature_info.func_arg_types is !null && source_index < meta_signature_info.func_arg_types.length()) {
            let parameter: TypeListNode = meta_signature_info.func_arg_types[source_index];
            source_parameter_types.append(parameter.type);
            source_parameter_modes.append(parameter.pass_mode);
            source_index++;
        }
        result_type = meta_signature_info.type;
    }

    let owned_start: Int = state.owned_values.length();
    let arguments: Vector(WirValueID) = [];
    if ((info is !null) && !info.is_varargs) {
        let lowered: WirCallArguments = wir_lower_bound_call_arguments(
            ref state,
            ref types,
            ref source,
            ref program,
            direct_arguments,
            info.arg_types,
            0,
            info.variadic_param,
            callable_name,
            call.pos
        );
        if (!lowered.valid) { return wir_no_expr(); }
        arguments = lowered.values;
    } else if (indirect_call) {
        if (signature_info is null) { return wir_no_expr(); }
        let signature: SymbolInfo = signature_info;
        let bound: BoundCallArgs = bind_callable_args(call.args, signature, call.pos);
        let lowered: WirCallArguments = wir_lower_bound_call_arguments(
            ref state,
            ref types,
            ref source,
            ref program,
            bound,
            signature.func_arg_types,
            0,
            signature.variadic_param,
            callable_name,
            call.pos
        );
        if (!lowered.valid) {
            return wir_no_expr();
        }
        arguments = lowered.values;
    } else {
        let parameter_count: Int = source_parameter_types.length();
        let i: Int = 0;
        while (call.args is !null && i < call.args.length()) {
            let argument: ArgNode = call.args[i];
            if ((argument.name.length() != 0) || argument.is_spread) {
                throw_invalid_syntax(call.pos, "Argument expansion is not available when calling a C variadic function.");
                return wir_no_expr();
            }
            let value: WirExpr = wir_no_expr();
            if (i < parameter_count) {
                value = wir_lower_expected_expr(ref state, ref types, ref source, ref program, argument.val, source_parameter_types[i]);
                if (value.value != NO_WIR_VALUE) {
                    value = wir_cast_expr(ref state, ref types, ref source, ref program, value, source_parameter_types[i], true, no_position());
                }
            } else {
                value = wir_lower_expr(ref state, ref types, ref source, ref program, argument.val);
            }
            if (value.value == NO_WIR_VALUE) {
                return wir_no_expr();
            }
            arguments.append(value.value);
            i++;
        }
    }
    let result: WirValueID = NO_WIR_VALUE;
    if indirect_call {
        if (signature_info is null) { return wir_no_expr(); }
        result = wir_call_callable(ref state, ref types, ref source, ref program, callee_value, indirect_source_type, signature_info, arguments);
    } else {
        result = wir_call(ref program, state.block, callee_value, arguments, "", no_wir_location());
    }
    wir_cleanup_temporaries(ref state, ref types, ref source, ref program, owned_start);
    if (result != NO_WIR_VALUE && wir_value_needs_drop(ref source, result_type)) {
        wir_track_owned(ref state, result, result_type);
    }
    return WirExpr(value=result, source_type=result_type);
}


func wir_lower_var(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: VarDeclareNode) -> Void {
    let const_access: Bool = has_node(node.value) && wir_lvalue_const(ref state, ref source, node.value);
    let source_type: Int = TYPE_AUTO;
    if (has_node(node.type_node)) {
        let declared: Int = resolve_type(ref source, node.type_node);
        if (declared != TYPE_AUTO) { source_type = declared; }
    }
    if (source_type == TYPE_VOID) {
        throw_type_error(node.pos, "Variable '" + node.name_tok.value + "' cannot have type Void.");
        return;
    }
    if (source_type == TYPE_POISON) {
        return;
    }

    if (source_type == TYPE_AUTO && has_node(node.value) && node_tag(node.value) == NODE_CALL) {
        let call: CallNode = get_call_node(ref source.arena, node.value);
        let info: Optional(FuncInfo) = wir_direct_function(ref state, ref source, call.callee);
        if (!(info is !null)) { info = wir_generic_call_function(ref state, ref source, call); }
        if ((info is !null) && is_fallible_type(ref source, info.ret_type) && !call.preserve_fallible) {
            throw_type_error(node.pos, "Fallible values cannot be stored; handle the call with '?'");
            return;
        }
    }
    if (source_type != TYPE_AUTO && has_node(node.value)) {
        let expected_named: Optional(NamedTypeInfo) = get_named_type(ref source, source_type);
        if ((expected_named is !null)) {
            let actual_type: Int = wir_argument_type(ref state, ref source, node.value);
            let actual_named: Optional(NamedTypeInfo) = get_named_type(ref source, actual_type);
            if (actual_type != TYPE_POISON && actual_type != source_type &&
                get_repr_type(ref source, actual_type) == get_repr_type(ref source, source_type) &&
                ((expected_named is !null) || (actual_named is !null))) {
                throw_type_error(node.pos, "Type mismatch. Expected " + get_type_name(ref source, source_type) + ", got " + get_type_name(ref source, actual_type));
                return;
            }
        }
    }
    let reference_binding: Bool = is_ref_binding_init(ref source, node.value) &&
                                  (source_type == TYPE_AUTO ||
                                   (!is_pointer_type(ref source, source_type) && source_type != TYPE_ANYPTR));
    let erased_generic: Bool = source_type == TYPE_GENERIC_STRUCT || source_type == TYPE_GENERIC_CLASS || source_type == TYPE_GENERIC_FUNCTION || source_type == TYPE_GENERIC_METHOD;
    let infer_literal: Bool = has_node(node.value) && source_type == TYPE_AUTO &&
                              (node_tag(node.value) == NODE_VECTOR_LIT || node_tag(node.value) == NODE_MAP_LIT);
    let infer_call: Bool = has_node(node.value) && source_type == TYPE_AUTO && node_tag(node.value) == NODE_CALL;
    if (reference_binding && source_type == TYPE_AUTO) {
        let reference: RefNode = get_ref_node(ref source.arena, node.value);
        source_type = wir_lvalue_type(ref state, ref source, reference.node);
    } else if (has_node(node.value) && (erased_generic || infer_literal || infer_call)) {
        let expression_type: Int = wir_argument_type(ref state, ref source, node.value);
        if (expression_type >= 100) { source_type = expression_type; }
    }

    if reference_binding {
        let reference: RefNode = get_ref_node(ref source.arena, node.value);
        if (!wir_stable_ref_target(ref state, ref source, reference.node)) {
            throw_type_error(node.pos, "Cannot bind a reference to storage that may move or be released.");
            return;
        }
        if (!node.is_const && wir_lvalue_const(ref state, ref source, reference.node)) {
            throw_type_error(node.pos, "Cannot bind a mutable reference to constant storage.");
            return;
        }
        let address: WirExpr = wir_lower_lvalue(ref state, ref types, ref source, ref program, reference.node);
        if (address.value == NO_WIR_VALUE) { return; }
        if (source_type == TYPE_AUTO) { source_type = address.source_type; }
        if (address.source_type != source_type) {
            throw_type_error(node.pos, "Type mismatch. Expected " + get_type_name(ref source, source_type) + ", got " + get_type_name(ref source, address.source_type) + ".");
            return;
        }

        let existing_index: Int = state.bindings.length() - 1;
        while (existing_index >= 0 && (state.bindings[existing_index].name != node.name_tok.value || !state.bindings[existing_index].pending_init)) { existing_index--; }
        if (existing_index >= 0) {
            let existing: WirBinding = state.bindings[existing_index];
            existing.address = address.value;
            existing.owns_value = false;
            existing.pending_init = false;
            existing.is_reference = true;
            existing.is_const_access = const_access;
            state.bindings[existing_index] = existing;
            return;
        }
        state.bindings.append(WirBinding(name=node.name_tok.value, source_type=source_type, address=address.value, is_const=node.is_const, is_const_access=const_access, owns_value=false, pending_init=false, is_reference=true));
        return;
    }
    let value: WirExpr = wir_no_expr();
    if (has_node(node.value)) {
        value = wir_lower_expected_expr(ref state, ref types, ref source, ref program, node.value, source_type);
    } else {
        let info: Optional(StructInfo) = source.struct_id_map.lookup(get_repr_type(ref source, source_type));
        let array: Optional(ArrayInfo) = source.array_info_map.lookup(get_repr_type(ref source, source_type));
        let vector: Optional(SymbolInfo) = source.vector_base_map.lookup(get_repr_type(ref source, source_type));
        let callable: Optional(SymbolInfo) = source.func_ret_map.lookup(get_repr_type(ref source, source_type));
        if (!(info is !null) || info.is_enum || info.is_interface || (array is !null) || (vector is !null) || (callable is !null)) {
            state.errors.append("local '" + node.name_tok.value + "' reached WIR lowering without an initializer");
            return;
        }
        let meta_info: StructInfo = info;

        let empty_args: Vector(ArgNode) = [];
        let call: CallNode = CallNode(type=NODE_CALL, callee=NO_NODE, args=empty_args, type_args=[], pos=node.pos, preserve_fallible=false);
        if (meta_info.is_class) {
            value = wir_lower_class_constructor(ref state, ref types, ref source, ref program, call, meta_info);
        } else {
            value = wir_lower_struct_constructor(ref state, ref types, ref source, ref program, call, meta_info);
        }
    }
    if (value.value == NO_WIR_VALUE) {
        return;
    }
    if (source_type == TYPE_AUTO) { source_type = value.source_type; }
    let source_callable: Bool = ((source.func_ret_map.lookup(value.source_type) is !null)) ||
                                ((source.method_ret_map.lookup(value.source_type) is !null));
    let target_callable: Bool = ((source.func_ret_map.lookup(source_type) is !null)) ||
                                ((source.method_ret_map.lookup(source_type) is !null));
    if (source_callable && target_callable && !callable_types_compatible(ref source, value.source_type, source_type)) {
        throw_type_error(node.pos, "Type mismatch. Expected " + get_type_name(ref source, source_type) + ", got " + get_type_name(ref source, value.source_type) + ".");
        return;
    }
    value = wir_cast_expr(ref state, ref types, ref source, ref program, value, source_type, true, node.pos);
    if (value.value == NO_WIR_VALUE) {
        return;
    }

    let existing_index: Int = state.bindings.length() - 1;
    while (existing_index >= 0 && (state.bindings[existing_index].name != node.name_tok.value || !state.bindings[existing_index].pending_init)) { existing_index--; }
    if (existing_index >= 0) {
        let existing: WirBinding = state.bindings[existing_index];
        if (existing.source_type != source_type) {
            state.errors.append("predeclared local '" + node.name_tok.value + "' has the wrong type in WIR lowering");
            return;
        }
        wir_move_or_retain(ref state, ref types, ref source, ref program, value);
        wir_emit_ownership_slot(ref state, ref types, ref source, ref program, existing.address, source_type, false);
        wir_store(ref program, state.block, value.value, existing.address, no_wir_location());
        existing.pending_init = false;
        existing.is_const_access = const_access;
        state.bindings[existing_index] = existing;
        return;
    }

    let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
    let address: WirValueID = wir_stack_alloc(ref program, state.entry, type_id, node.name_tok.value + ".addr", no_wir_location());
    wir_move_or_retain(ref state, ref types, ref source, ref program, value);
    wir_store(ref program, state.block, value.value, address, no_wir_location());
    let owns_value: Bool = wir_value_needs_drop(ref source, source_type);
    state.bindings.append(WirBinding(name=node.name_tok.value, source_type=source_type, address=address, is_const=node.is_const, is_const_access=const_access, owns_value=owns_value, pending_init=false, is_reference=false));
}

func wir_loop_has_break(ref source: Compiler, node: NodeID) -> Bool {
    if (!has_node(node)) { return false; }
    let kind: Int = node_tag(node);
    if (kind == NODE_BREAK) { return true; }
    if (kind == NODE_WHILE || kind == NODE_FOR) { return false; }
    if (kind == NODE_BLOCK) {
        let block: BlockNode = get_block_node(ref source.arena, node);
        let i: Int = 0;
        while (block.stmts is !null && i < block.stmts.length()) {
            if (wir_loop_has_break(ref source, block.stmts[i])) { return true; }
            i++;
        }
        return false;
    }
    if (kind == NODE_IF) {
        let branch: IfNode = get_if_node(ref source.arena, node);
        return wir_loop_has_break(ref source, branch.body) || wir_loop_has_break(ref source, branch.else_body);
    }
    if (kind == NODE_CATCH) {
        let caught: CatchNode = get_catch_node(ref source.arena, node);
        return wir_loop_has_break(ref source, caught.stmt) || wir_loop_has_break(ref source, caught.body);
    }
    return false;
}

func wir_lower_stmt(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: NodeID) -> Void {
    if (!has_node(node)) { return; }
    let kind = node_tag(node);
    if (kind == NODE_WHILE || kind == NODE_FOR) { source.flow_types = []; }
    if (kind == NODE_VAR_DECL) { flow_forget(ref source, get_var_decl_node(ref source.arena, node).name_tok.value, false); }
    wir_lower_raw_stmt(ref state, ref types, ref source, ref program, node);
    if (kind == NODE_VAR_ASSIGN) { flow_forget(ref source, get_var_assign_node(ref source.arena, node).name_tok.value, false); }
    if (kind == NODE_FIELD_ASSIGN) {
        let field = get_field_assign_node(ref source.arena, node);
        flow_forget(ref source, format_ast_path(ref source, field.obj) + "." + field.field_name, false);
    }
    if (kind == NODE_WHILE || kind == NODE_FOR || kind == NODE_CATCH) { source.flow_types = []; }
}

func wir_lower_raw_stmt(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: NodeID) -> Void {
    if (state.terminated || !has_node(node)) { return; }
    let kind: Int = node_tag(node);
    if (kind == NODE_BLOCK) {
        wir_lower_block(ref state, ref types, ref source, ref program, node);
        return;
    }
    if (kind == NODE_CATCH) {
        wir_lower_catch(ref state, ref types, ref source, ref program, get_catch_node(ref source.arena, node));
        return;
    }
    if (kind == NODE_TRY_UNWRAP) {
        wir_lower_expr(ref state, ref types, ref source, ref program, node);
        return;
    }
    if (kind == NODE_THROW) {
        wir_lower_throw(ref state, ref types, ref source, ref program, get_throw_node(ref source.arena, node));
        return;
    }
    if (kind == NODE_VAR_DECL) {
        wir_lower_var(ref state, ref types, ref source, ref program, get_var_decl_node(ref source.arena, node));
        return;
    }
    if (kind == NODE_FUNC_DEF) {
        wir_lower_local_function(ref state, ref types, ref source, ref program, get_func_def_node(ref source.arena, node));
        return;
    }
    if (kind == NODE_VAR_ASSIGN) {
        let statement: VarAssignNode = get_var_assign_node(ref source.arena, node);
        let binding: WirBinding = wir_find_binding(ref state, statement.name_tok.value)?;
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
            if (global_value.value == NO_WIR_VALUE) {
                return;
            }
            global_value = wir_cast_expr(ref state, ref types, ref source, ref program, global_value, global.source_type, true, no_position());
            if (global_value.value == NO_WIR_VALUE) {
                return;
            }
            let global_address: WirValueID = wir_global_value(ref program, global_id);
            wir_move_or_retain(ref state, ref types, ref source, ref program, global_value);
            wir_emit_ownership_slot(ref state, ref types, ref source, ref program, global_address, global.source_type, false);
            wir_store(ref program, state.block, global_value.value, global_address, no_wir_location());
            return;
        }
        if (binding.is_const) {
            state.errors.append("const local '" + statement.name_tok.value + "' reached WIR lowering with an assignment");
            return;
        }
        let value: WirExpr = wir_lower_expected_expr(ref state, ref types, ref source, ref program, statement.value, binding.source_type);
        if (value.value == NO_WIR_VALUE) { return; }
        value = wir_cast_expr(ref state, ref types, ref source, ref program, value, binding.source_type, true, statement.pos);
        if (value.value == NO_WIR_VALUE) {
            return;
        }
        wir_move_or_retain(ref state, ref types, ref source, ref program, value);
        wir_emit_ownership_slot(ref state, ref types, ref source, ref program, binding.address, binding.source_type, false);
        wir_store(ref program, state.block, value.value, binding.address, no_wir_location());

        let binding_index: Int = state.bindings.length() - 1;
        while (binding_index >= 0 && state.bindings[binding_index].name != statement.name_tok.value) {
            binding_index--;
        }
        if (binding_index >= 0) {
            let updated: WirBinding = state.bindings[binding_index];
            updated.is_const_access = wir_lvalue_const(ref state, ref source, statement.value);
            state.bindings[binding_index] = updated;
        }
        return;
    }
    if (kind == NODE_FIELD_ASSIGN) {
        let statement: FieldAssignNode = get_field_assign_node(ref source.arena, node);
        let global: WirSourceGlobal = wir_member_global(ref state, ref source, statement.obj, statement.field_name);
        if (has_wir_source_global(global)) {
            let global_id: WirGlobalID = wir_find_global(program, global.name);
            if (global_id == NO_WIR_GLOBAL) {
                state.errors.append("global '" + global.name + "' was not declared before WIR lowering");
                return;
            }
            if (global.is_const) {
                state.errors.append("const global '" + global.name + "' reached WIR lowering with an assignment");
                return;
            }
            let global_value: WirExpr = wir_lower_expected_expr(ref state, ref types, ref source, ref program, statement.value, global.source_type);
            if (global_value.value == NO_WIR_VALUE) {
                return;
            }
            global_value = wir_cast_expr(ref state, ref types, ref source, ref program, global_value, global.source_type, true, no_position());
            if (global_value.value == NO_WIR_VALUE) { return; }
            let global_address: WirValueID = wir_global_value(ref program, global_id);
            wir_move_or_retain(ref state, ref types, ref source, ref program, global_value);
            wir_emit_ownership_slot(ref state, ref types, ref source, ref program, global_address, global.source_type, false);
            wir_store(ref program, state.block, global_value.value, global_address, no_wir_location());
            return;
        }
        if (wir_field_const(ref state, ref source, statement.obj, statement.field_name)) {
            let name: String = expr_root_name(ref source, statement.obj);
            throw_type_error(statement.pos, "Cannot modify value through const access '" + name + "'");
            return;
        }
        let write_facts = flow_write_facts(ref source, statement.obj);
        let address: WirExpr = wir_lower_field_lvalue(ref state, ref types, ref source, ref program, statement.obj, statement.field_name);
        if (address.value == NO_WIR_VALUE) {
            return;
        }
        let value: WirExpr = wir_lower_expected_expr(ref state, ref types, ref source, ref program, statement.value, address.source_type);
        if (value.value == NO_WIR_VALUE) {
            return;
        }
        if (!flow_write_valid(ref source, write_facts)) {
            throw_type_error(statement.pos, "Optional field assignment loses its null check while evaluating the assigned value.");
            return;
        }
        value = wir_cast_expr(ref state, ref types, ref source, ref program, value, address.source_type, true, no_position());
        if (value.value == NO_WIR_VALUE) {
            return;
        }
        wir_move_or_retain(ref state, ref types, ref source, ref program, value);
        wir_emit_ownership_slot(ref state, ref types, ref source, ref program, address.value, address.source_type, false);
        wir_store(ref program, state.block, value.value, address.value, no_wir_location());
        return;
    }
    if (kind == NODE_INDEX_ASSIGN) {
        let statement: IndexAssignNode = get_index_assign_node(ref source.arena, node);
        if (wir_lvalue_const(ref state, ref source, statement.target)) {
            state.errors.append("const array reached WIR lowering with an index assignment");
            return;
        }
        let target_type: Int = get_repr_type(ref source, wir_lvalue_type(ref state, ref source, statement.target));
        let owner: Optional(StructInfo) = source.struct_id_map.lookup(target_type);
        if ((owner is !null) && owner.is_class) {
            let meta_owner: StructInfo = owner;
            let has_put: Bool = false;
            let method_index: Int = 0;
            while (meta_owner.vtable is !null && method_index < meta_owner.vtable.length()) {
                let candidate: FuncInfo = meta_owner.vtable[method_index];
                if (candidate.base_name == "put") {
                    has_put = true;
                    break;
                }
                method_index++;
            }
            if has_put {
                let callee: NodeID = add_field_access_node(ref source.arena, FieldAccessNode(type=NODE_FIELD_ACCESS, obj=statement.target, field_name="put", pos=statement.pos));
                let arguments: Vector(ArgNode) = [ArgNode(val=statement.index_node, name="", is_spread=false), ArgNode(val=statement.value, name="", is_spread=false)];
                let call: CallNode = CallNode(type=NODE_CALL, callee=callee, args=arguments, type_args=[], pos=statement.pos, preserve_fallible=false);
                let result: WirMemberCall = wir_lower_class_call(ref state, ref types, ref source, ref program, call);
                if (!result.handled) {
                    state.errors.append("index assignment method was not lowered to WIR");
                }
                return;
            }
        }
        let write_facts: Vector(FlowType) = [];
        let array = source.array_info_map.lookup(target_type);
        if ((array is !null) && array.size >= 0) { write_facts = flow_write_facts(ref source, statement.target); }
        let address: WirExpr = wir_lower_index_lvalue(ref state, ref types, ref source, ref program, statement.target, statement.index_node);
        if (address.value == NO_WIR_VALUE) {
            return;
        }
        let value: WirExpr = wir_lower_expected_expr(ref state, ref types, ref source, ref program, statement.value, address.source_type);
        if (value.value == NO_WIR_VALUE) { return; }
        if (!flow_write_valid(ref source, write_facts)) {
            throw_type_error(statement.pos, "Optional index assignment loses its null check while evaluating the assigned value.");
            return;
        }
        value = wir_cast_expr(ref state, ref types, ref source, ref program, value, address.source_type, true, no_position());
        if (value.value == NO_WIR_VALUE) {
            return;
        }
        wir_move_or_retain(ref state, ref types, ref source, ref program, value);
        wir_emit_ownership_slot(ref state, ref types, ref source, ref program, address.value, address.source_type, false);
        wir_store(ref program, state.block, value.value, address.value, no_wir_location());
        return;
    }
    if (kind == NODE_PTR_ASSIGN) {
        let statement: PtrAssignNode = get_ptr_assign_node(ref source.arena, node);
        let dereference: DerefNode = get_deref_node(ref source.arena, statement.pointer);
        if (wir_lvalue_const(ref state, ref source, dereference.node)) {
            state.errors.append("const pointer reached WIR lowering with an indirect assignment");
            return;
        }
        let pointer: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, dereference.node);
        if (pointer.value == NO_WIR_VALUE) {
            return;
        }
        let level: Int = 0;
        while (level + 1 < dereference.level) {
            let base: Optional(SymbolInfo) = source.ptr_base_map.lookup(pointer.source_type);
            if (!(base is !null) || base.type == TYPE_VOID) {
                state.errors.append("invalid pointer assignment reached WIR lowering");
                return;
            }
            let meta_base: SymbolInfo = base;
            wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [pointer.value], [], no_wir_location());
            pointer = WirExpr(value=wir_load(ref program, state.block, pointer.value, "", no_wir_location()), source_type=meta_base.type);
            level++;
        }
        let target: Optional(SymbolInfo) = source.ptr_base_map.lookup(pointer.source_type);
        if (!(target is !null) || target.type == TYPE_VOID) {
            state.errors.append("pointer assignment target is not a typed pointer in WIR lowering");
            return;
        }
        wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [pointer.value], [], no_wir_location());
        let value: WirExpr = wir_lower_expected_expr(ref state, ref types, ref source, ref program, statement.value, target.type);
        if (value.value == NO_WIR_VALUE) {
            return;
        }
        value = wir_cast_expr(ref state, ref types, ref source, ref program, value, target.type, true, no_position());
        if (value.value == NO_WIR_VALUE) { return; }
        wir_move_or_retain(ref state, ref types, ref source, ref program, value);
        wir_emit_ownership_slot(ref state, ref types, ref source, ref program, pointer.value, target.type, false);
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
        let statement: ReturnNode = get_return_node(ref source.arena, node);
        let function: WirFunction = program.arena.functions[wir_id_index(UInt32(state.function))];
        let signature: WirType = program.arena.types[wir_id_index(UInt32(function.type_id))];
        let result: WirExpr = wir_no_expr();
        if (state.return_type == TYPE_VOID && has_node(statement.value)) {
            throw_type_error(statement.pos, "Void function cannot return a value.");
            return;
        }
        if (is_fallible_type(ref source, state.return_type)) {
            let inner_type: Int = get_inner_fallible_type(ref source, state.return_type);
            let value: WirExpr = wir_no_expr();
            if (has_node(statement.value)) {
                value = wir_lower_expr(ref state, ref types, ref source, ref program, statement.value);
                if (value.value == NO_WIR_VALUE) { return; }
                if (!check_null_return(ref source, value.source_type, state.return_type, statement.pos)) { return; }
            }
            if (value.value != NO_WIR_VALUE && value.source_type == state.return_type) {
                result = value;
                wir_move_or_retain(ref state, ref types, ref source, ref program, result);
            } else if (inner_type == TYPE_VOID) {
                if (value.value != NO_WIR_VALUE) {
                    throw_type_error(statement.pos, "Void function cannot return a value.");
                    return;
                }
                result = WirExpr(value=wir_success_result(ref state, ref types, ref source, ref program, value), source_type=state.return_type);
            } else {
                if (value.value == NO_WIR_VALUE) {
                    throw_type_error(statement.pos, "Non-void function must return a value.");
                    return;
                }
                value = wir_cast_expr(ref state, ref types, ref source, ref program, value, inner_type, true, no_position());
                if (value.value == NO_WIR_VALUE) { return; }
                wir_move_or_retain(ref state, ref types, ref source, ref program, value);
                result = WirExpr(value=wir_success_result(ref state, ref types, ref source, ref program, value), source_type=state.return_type);
            }
            if (result.value == NO_WIR_VALUE || wir_value_type(ref program, result.value) != signature.result) {
                state.errors.append("fallible return value has the wrong WIR type");
                return;
            }
        } else if (has_node(statement.value)) {
            result = wir_lower_expected_expr(ref state, ref types, ref source, ref program, statement.value, state.return_type);
            if (result.value == NO_WIR_VALUE) { return; }
            if (!check_null_return(ref source, result.source_type, state.return_type, statement.pos)) { return; }
        }
        if (signature.result == program.void_type) {
            if (result.value != NO_WIR_VALUE) {
                throw_type_error(statement.pos, "Void function cannot return a value.");
                return;
            }
        } else if (result.value == NO_WIR_VALUE) {
            throw_type_error(statement.pos, "Non-void function must return a value.");
            return;
        } else if (!is_fallible_type(ref source, state.return_type)) {
            result = wir_cast_expr(ref state, ref types, ref source, ref program, result, state.return_type, true, statement.pos);
            if (result.value == NO_WIR_VALUE || wir_value_type(ref program, result.value) != signature.result) {
                state.errors.append("return value reached WIR lowering with the wrong type");
                return;
            }
            wir_move_or_retain(ref state, ref types, ref source, ref program, result);
        }
        wir_cleanup_temporaries(ref state, ref types, ref source, ref program, 0);
        wir_cleanup_bindings(ref state, ref types, ref source, ref program, 0);
        wir_return(ref program, state.block, result.value, no_wir_location());
        state.terminated = true;
        return;
    }
    if (kind == NODE_IF) {
        let statement: IfNode = get_if_node(ref source.arena, node);
        let selected: Int = fold_target_cond(ref source, statement.condition);
        if (selected == 1) {
            wir_lower_block(ref state, ref types, ref source, ref program, statement.body);
            return;
        }
        if (selected == 0) {
            if (!has_node(statement.else_body)) {
                return;
            }
            if (node_tag(statement.else_body) == NODE_IF) {
                wir_lower_stmt(ref state, ref types, ref source, ref program, statement.else_body);
            } else {
                wir_lower_block(ref state, ref types, ref source, ref program, statement.else_body);
            }
            return;
        }
        let condition_owned_start: Int = state.owned_values.length();
        let condition: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, statement.condition);
        if (condition.value == NO_WIR_VALUE) {
            return;
        }
        if (condition.source_type != TYPE_BOOL) {
            state.errors.append("if condition reached WIR lowering with a non-Bool type");
            return;
        }
        let condition_owned: Vector(WirOwnedValue) = wir_copy_owned(state.owned_values);
        let incoming = flow_copy(source.flow_types);

        let parent_bindings: Int = state.bindings.length();
        let then_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "if.then."), []);
        if (!has_node(statement.else_body)) {
            let merge_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "if.end."), []);
            wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [condition.value], [wir_edge(then_block, []), wir_edge(merge_block, [])], no_wir_location());

            state.block = then_block;
            state.terminated = false;
            wir_apply_flow_guard(ref state, ref source, statement.condition, true);
            wir_lower_block(ref state, ref types, ref source, ref program, statement.body);
            let then_facts = flow_copy(source.flow_types);
            let then_terminated = state.terminated;
            if (!state.terminated) {
                wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(merge_block, [])], no_wir_location());
            }

            wir_restore_bindings(ref state, parent_bindings);
            source.flow_types = flow_copy(incoming);
            wir_apply_flow_guard(ref state, ref source, statement.condition, false);
            if (!then_terminated) { source.flow_types = flow_intersect(then_facts, source.flow_types); }
            state.block = merge_block;
            state.terminated = false;
            state.owned_values = condition_owned;
            wir_cleanup_temporaries(ref state, ref types, ref source, ref program, condition_owned_start);
            return;
        }

        let else_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "if.else."), []);
        wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [condition.value], [wir_edge(then_block, []), wir_edge(else_block, [])], no_wir_location());

        state.block = then_block;
        state.terminated = false;
        wir_apply_flow_guard(ref state, ref source, statement.condition, true);
        wir_lower_block(ref state, ref types, ref source, ref program, statement.body);
        let then_end: WirBlockID = state.block;
        let then_terminated: Bool = state.terminated;
        let then_facts = flow_copy(source.flow_types);

        wir_restore_bindings(ref state, parent_bindings);
        state.owned_values = wir_copy_owned(condition_owned);
        state.block = else_block;
        state.terminated = false;
        source.flow_types = flow_copy(incoming);
        wir_apply_flow_guard(ref state, ref source, statement.condition, false);
        if (node_tag(statement.else_body) == NODE_IF) {
            wir_lower_stmt(ref state, ref types, ref source, ref program, statement.else_body);
        } else {
            wir_lower_block(ref state, ref types, ref source, ref program, statement.else_body);
        }
        let else_end: WirBlockID = state.block;
        let else_terminated: Bool = state.terminated;
        if (!then_terminated) {
            if else_terminated { source.flow_types = then_facts; }
            else { source.flow_types = flow_intersect(then_facts, source.flow_types); }
        }

        wir_restore_bindings(ref state, parent_bindings);
        if (then_terminated && else_terminated) {
            state.terminated = true;
            return;
        }

        let merge_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "if.end."), []);
        if (!then_terminated) {
            wir_append(ref program, then_end, WirOpcode.Jump, program.void_type, [], [wir_edge(merge_block, [])], no_wir_location());
        }
        if (!else_terminated) {
            wir_append(ref program, else_end, WirOpcode.Jump, program.void_type, [], [wir_edge(merge_block, [])], no_wir_location());
        }
        state.block = merge_block;
        state.terminated = false;
        state.owned_values = condition_owned;
        wir_cleanup_temporaries(ref state, ref types, ref source, ref program, condition_owned_start);
        return;
    }
    if (kind == NODE_WHILE) {
        let statement: WhileNode = get_while_node(ref source.arena, node);
        let condition_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "while.cond."), []);
        let body_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "while.body."), []);
        let end_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "while.end."), []);
        wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(condition_block, [])], no_wir_location());

        state.block = condition_block;
        state.terminated = false;
        let condition: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, statement.condition);
        if (condition.value == NO_WIR_VALUE) {
            return;
        }
        if (condition.source_type != TYPE_BOOL) {
            state.errors.append("while condition reached WIR lowering with a non-Bool type");
            return;
        }
        let constant_true: Bool = node_tag(statement.condition) == NODE_BOOL && get_bool_node(ref source.arena, statement.condition).value == 1;
        let constant_false: Bool = node_tag(statement.condition) == NODE_BOOL && get_bool_node(ref source.arena, statement.condition).value == 0;
        if constant_true {
            wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(body_block, [])], no_wir_location());
        } else if (constant_false) {
            wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(end_block, [])], no_wir_location());
        } else {
            wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [condition.value], [wir_edge(body_block, []), wir_edge(end_block, [])], no_wir_location());
        }

        state.loops.append(WirLoop(continue_block=condition_block, break_block=end_block, binding_count=state.bindings.length()));
        state.block = body_block;
        state.terminated = false;
        wir_apply_flow_guard(ref state, ref source, statement.condition, true);
        wir_lower_block(ref state, ref types, ref source, ref program, statement.body);
        if (!state.terminated) {
            wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(condition_block, [])], no_wir_location());
        }
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
    if (kind == NODE_FOR) {
        let statement: ForNode = get_for_node(ref source.arena, node);
        let outer_bindings: Int = state.bindings.length();
        let constant_true: Bool = !has_node(statement.cond);
        if (has_node(statement.cond) && node_tag(statement.cond) == NODE_BOOL) {
            constant_true = get_bool_node(ref source.arena, statement.cond).value == 1;
        }
        if (has_node(statement.init)) {
            wir_lower_stmt(ref state, ref types, ref source, ref program, statement.init);
        }
        if (state.terminated) {
            return;
        }

        let condition_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "for.cond."), []);
        let body_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "for.body."), []);
        let step_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "for.step."), []);
        let end_block: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "for.end."), []);
        wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(condition_block, [])], no_wir_location());

        state.block = condition_block;
        state.terminated = false;
        if (has_node(statement.cond)) {
            let condition: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, statement.cond);
            if (condition.value == NO_WIR_VALUE) {
                return;
            }
            if (condition.source_type != TYPE_BOOL) {
                state.errors.append("for condition reached WIR lowering with a non-Bool type");
                return;
            }
            wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [condition.value], [wir_edge(body_block, []), wir_edge(end_block, [])], no_wir_location());
        } else {
            wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(body_block, [])], no_wir_location());
        }

        let loop_bindings: Int = state.bindings.length();
        state.loops.append(WirLoop(continue_block=step_block, break_block=end_block, binding_count=loop_bindings));
        state.block = body_block;
        state.terminated = false;
        if (has_node(statement.cond)) { wir_apply_flow_guard(ref state, ref source, statement.cond, true); }
        wir_lower_block(ref state, ref types, ref source, ref program, statement.body);
        if (!state.terminated) {
            wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(step_block, [])], no_wir_location());
        }

        state.block = step_block;
        state.terminated = false;
        if (has_node(statement.step)) {
            let temporary_count: Int = state.owned_values.length();
            wir_lower_stmt(ref state, ref types, ref source, ref program, statement.step);
            if (!state.terminated) {
                wir_cleanup_temporaries(ref state, ref types, ref source, ref program, temporary_count);
            }
        }
        if (!state.terminated) {
            wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(condition_block, [])], no_wir_location());
        }

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
            wir_restore_bindings(ref state, outer_bindings);
            return;
        }
        state.terminated = false;
        wir_cleanup_bindings(ref state, ref types, ref source, ref program, outer_bindings);
        wir_restore_bindings(ref state, outer_bindings);
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
        wir_cleanup_temporaries(ref state, ref types, ref source, ref program, 0);
        wir_cleanup_bindings(ref state, ref types, ref source, ref program, loop.binding_count);
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
    let block: BlockNode = get_block_node(ref source.arena, node);
    let binding_count: Int = state.bindings.length();
    if (!state.reference_checked) {
        state.reference_checked = true;
        if (has_index_refs(ref source)) {
            let inputs: Dict(String, SymbolInfo) = Dict();
            let i = 0;
            while (i < state.bindings.length()) {
                let binding = state.bindings[i];
                inputs.put(binding.name, SymbolInfo(reg="ref.check", type=binding.source_type, is_const=binding.is_const, is_reference=binding.is_reference, origin_type=0, is_const_access=false, is_ref_param=false, func_arg_types=[], arg_names=[], variadic_param=0));
                i++;
            }
            if (!check_body_refs(ref source, node, inputs)) { return; }
        }
    }
    let i: Int = 0;
    let errors_before = GLOBAL_ERROR_COUNT;
    while (i < block.stmts.length() && !state.terminated && GLOBAL_ERROR_COUNT == errors_before) {
        let temporary_count: Int = state.owned_values.length();
        wir_lower_stmt(ref state, ref types, ref source, ref program, block.stmts[i]);
        if (!state.terminated && GLOBAL_ERROR_COUNT == errors_before) {
            wir_cleanup_temporaries(ref state, ref types, ref source, ref program, temporary_count);
        }
        i++;
    }
    if (!state.terminated && GLOBAL_ERROR_COUNT == errors_before) {
        wir_cleanup_bindings(ref state, ref types, ref source, ref program, binding_count);
    }
    // remove facts for block locals before their names can resolve to an outer binding.
    if (source.flow_types.length() != 0) {
        let local = binding_count;
        while (local < state.bindings.length()) {
            flow_forget(ref source, state.bindings[local].name, false);
            local++;
        }
    }
    wir_restore_bindings(ref state, binding_count);
}

func wir_lower_function_body(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, info: FuncInfo, body: NodeID) -> WirFuncID {
    let saved_facts = source.flow_types;
    let saved_exposed = source.flow_exposed;
    source.flow_types = [];
    source.flow_exposed = [];
    let result = wir_lower_function_impl(ref types, ref source, ref program, info, body);
    source.flow_types = saved_facts;
    source.flow_exposed = saved_exposed;
    return result;
}

func wir_lower_function_impl(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, info: FuncInfo, body: NodeID) -> WirFuncID {
    let function_id: WirFuncID = wir_find_function(program, info.name);
    if (function_id == NO_WIR_FUNC) {
        function_id = wir_lower_function_decl(ref types, ref source, ref program, info);
    }
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
    let state: WirFunctionLowering = WirFunctionLowering(
        function=function_id,
        return_type=info.ret_type,
        entry=entry,
        block=entry,
        bindings=[],
        loops=[],
        error_targets=[],
        owned_values=[],
        errors=[],
        terminated=false,
        next_block=0,
        binding_indices=null,
        indexed_bindings=0,
        reference_checked=false
    );
    let i: Int = 0;
    while (i < function.parameters.length()) {
        let parameter: WirValueID = function.parameters[i];
        let source_parameter: TypeListNode = info.arg_types[i];
        let name: String = program.arena.values[wir_id_index(UInt32(parameter))].name;
        if (source_parameter.pass_mode == PARAM_REF) {
            state.bindings.append(WirBinding(name=name, source_type=source_parameter.type, address=parameter, is_const=false, owns_value=false, pending_init=false, is_reference=true, is_const_access=false));
        } else {
            let source_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_parameter.type);
            let address: WirValueID = wir_stack_alloc(ref program, entry, source_type, name + ".addr", no_wir_location());
            // retaining an earlier aggregate can split the entry block to select a union arm.
            // later parameters still get entry allocas, their stores belong to the live block.
            wir_store(ref program, state.block, parameter, address, no_wir_location());
            // method receivers borrow the object held by the caller. Releasing self here
            // would make a deinitializer enter its own drop glue again.
            let is_receiver: Bool = i == 0 && name == "self";
            let owns_value: Bool = !is_receiver && wir_value_needs_drop(ref source, source_parameter.type);
            if owns_value {
                wir_emit_ownership_value(ref state, ref types, ref source, ref program, parameter, source_parameter.type, true);
            }
            state.bindings.append(WirBinding(name=name, source_type=source_parameter.type, address=address, is_const=false, owns_value=owns_value, pending_init=false, is_const_access=false, is_reference=false));
        }
        i++;
    }

    let errors_before = GLOBAL_ERROR_COUNT;
    wir_lower_block(ref state, ref types, ref source, ref program, body);
    // the failed body has a source diagnostic, its incomplete CFG is not a missing return
    if (GLOBAL_ERROR_COUNT != errors_before) { return function_id; }
    let signature: WirType = program.arena.types[wir_id_index(UInt32(function.type_id))];
    if (!state.terminated) {
        if (signature.result == program.void_type) {
            wir_cleanup_temporaries(ref state, ref types, ref source, ref program, 0);
            wir_cleanup_bindings(ref state, ref types, ref source, ref program, 0);
            wir_return(ref program, state.block, NO_WIR_VALUE, no_wir_location());
        } else if (is_fallible_type(ref source, state.return_type) && get_inner_fallible_type(ref source, state.return_type) == TYPE_VOID) {
            let result: WirValueID = wir_success_result(ref state, ref types, ref source, ref program, wir_no_expr());
            if (result == NO_WIR_VALUE) {
                state.errors.append("failed to build the implicit success result for fallible Void function '" + info.name + "'");
            } else {
                wir_cleanup_temporaries(ref state, ref types, ref source, ref program, 0);
                wir_cleanup_bindings(ref state, ref types, ref source, ref program, 0);
                wir_return(ref program, state.block, result, no_wir_location());
            }
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
