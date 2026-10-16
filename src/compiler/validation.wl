// src/compiler/validation.wl
import * from "../frontend/ast.wl"
import * from "../frontend/arena.wl"
import * from "context.wl"
import * from "../frontend/tokens.wl"
import * from "../frontend/diagnostics.wl"
import parse_const_uint128, parse_decimal_float_literal from "constants.wl"
import get_target_pointer_bits from "target.wl"


func is_dict_key_type(ref c: Compiler, type_id: Int) -> Bool {
    if (type_id == TYPE_NULL || type_id == TYPE_NULLPTR || type_id == TYPE_ANYPTR || type_id == TYPE_STRING) {
        return true;
    }
    if (is_primitive_type(type_id)) {
        return type_id != TYPE_ANY_ERROR;
    }
    if (is_pointer_type(ref c, type_id)) { return true; }

    let info: Optional(StructInfo) = c.struct_id_map.lookup(type_id);
    if ((info is !null)) {
        if (info.is_enum || info.is_interface) { return true; }
        if (info.is_class) {
            return info.name != "dict.Dict" && info.name != "Dict" && !info.name.starts_with("dict.Dict$") && !info.name.starts_with("Dict$");
        }
        return false;
    }
    if ((c.func_ret_map.lookup(type_id) is !null) || (c.method_ret_map.lookup(type_id) is !null)) {
        return true;
    }
    return false;
}

func is_typed_dict(ref c: Compiler, info: Optional(StructInfo)) -> Bool {
    if (info is null) { return false; }

    let template: Optional(GenericTemplate) = c.generic_instance_templates.lookup("" + info.type_id);
    return (template is !null) && (template.name == "Dict" || template.name.ends_with(".Dict"));
}

func signed_negative_limit(type_id: Int) -> UInt128 {
    if (type_id == TYPE_INT8) {
        return UInt128(128);
    }
    if (type_id == TYPE_INT16) {
        return UInt128(32768);
    }
    if (type_id == TYPE_INT) {
        return UInt128(2147483648UL);
    }
    if (type_id == TYPE_INTSIZE && get_target_pointer_bits() == 32) {
        return UInt128(2147483648UL);
    }
    if (type_id == TYPE_LONG || type_id == TYPE_INTSIZE) { return UInt128(9223372036854775808UL); }
    if (type_id == TYPE_INT128) {
        return 170141183460469231731687303715884105728ULL;
    }
    return UInt128(0);
}

func positive_integer_limit(type_id: Int) -> UInt128 {
    if (type_id == TYPE_INT8) { return UInt128(127); }
    if (type_id == TYPE_INT16) {
        return UInt128(32767);
    }
    if (type_id == TYPE_INT) {
        return UInt128(2147483647);
    }
    if (type_id == TYPE_INTSIZE && get_target_pointer_bits() == 32) {
        return UInt128(2147483647);
    }
    if (type_id == TYPE_LONG || type_id == TYPE_INTSIZE) {
        return UInt128(9223372036854775807L);
    }
    if (type_id == TYPE_INT128) {
        return 170141183460469231731687303715884105727ULL;
    }
    if (type_id == TYPE_BYTE) { return UInt128(255); }
    if (type_id == TYPE_UINT16) {
        return UInt128(65535);
    }
    if (type_id == TYPE_UINT32) {
        return UInt128(4294967295UL);
    }
    if (type_id == TYPE_UINTSIZE && get_target_pointer_bits() == 32) {
        return UInt128(4294967295UL);
    }
    if (type_id == TYPE_UINT64 || type_id == TYPE_UINTSIZE) {
        return UInt128(18446744073709551615UL);
    }
    if (type_id == TYPE_UINT128) {
        return 340282366920938463463374607431768211455ULL;
    }
    return UInt128(0);
}

func float_integer_limit(type_id: Int) -> Float {
    let bits: Int = get_type_bitwidth(type_id);
    if (is_signed_integer(type_id)) { bits -= 1; }
    let limit: Float = 1.0;
    let i: Int = 0;
    while (i < bits) {
        limit *= 2.0;
        i += 1;
    }
    return limit;
}

func is_numeric_literal_expression(ref c: Compiler, node: NodeID) -> Bool {
    if (!has_node(node)) { return false; }
    let base: Int = node_tag(node);
    if (base == NODE_INT || base == NODE_FLOAT ||
        base == NODE_CHAR || base == NODE_BOOL) {
        return true;
    }
    if (base == NODE_UNARYOP) {
        let unary: UnaryOpNode = get_unary_node(ref c.arena, node);
        if (unary.op_tok.type == TOK_PLUS || unary.op_tok.type == TOK_SUB) {
            return is_numeric_literal_expression(ref c, unary.node);
        }
    }
    return false;
}

func validate_explicit_literal_cast(ref c: Compiler, node: NodeID, target_type: Int, pos: Position) -> Bool {
    target_type = get_repr_type(ref c, target_type);
    if (!has_node(node)) { return true; }
    let base: Int = node_tag(node);
    let magnitude: UInt128 = UInt128(0);
    let negative: Bool = false;
    let literal_text: String = "";
    let is_float_literal: Bool = false;
    let float_value: Float = 0.0;

    if (base == NODE_INT) {
        let integer: IntNode = get_int_node(ref c.arena, node);
        literal_text = integer.tok.value;
        magnitude = parse_const_uint128(integer.tok.value, integer.pos);
    } else if (base == NODE_FLOAT) {
        let float_node: FloatNode = get_float_node(ref c.arena, node);
        literal_text = float_node.tok.value;
        float_value = parse_decimal_float_literal(float_node.tok.value);
        is_float_literal = true;
    } else if (base == NODE_CHAR) {
        let char_node: CharNode = get_char_node(ref c.arena, node);
        literal_text = "'" + char_node.tok.value + "'";
        magnitude = UInt128(string_to_int(char_node.tok.value, char_node.pos));
    } else if (base == NODE_BOOL) {
        return true;
    } else if (base == NODE_UNARYOP) {
        let unary: UnaryOpNode = get_unary_node(ref c.arena, node);
        if (unary.op_tok.type == TOK_PLUS) {
            return validate_explicit_literal_cast(ref c, unary.node, target_type, pos);
        }
        let inner_base: Int = node_tag(unary.node);
        if (unary.op_tok.type != TOK_SUB) { return true; }
        if (inner_base == NODE_INT) {
            let integer: IntNode = get_int_node(ref c.arena, unary.node);
            literal_text = "-" + integer.tok.value;
            magnitude = parse_const_uint128(integer.tok.value, integer.pos);
            negative = magnitude != UInt128(0);
        } else if (inner_base == NODE_FLOAT) {
            let float_node: FloatNode = get_float_node(ref c.arena, unary.node);
            literal_text = "-" + float_node.tok.value;
            float_value = 0.0 - parse_decimal_float_literal(float_node.tok.value);
            is_float_literal = true;
        } else {
            return true;
        }
    } else {
        return true;
    }

    let target_name: String = get_type_name(ref c, target_type);
    if is_float_literal {
        if (!is_integer_type(target_type) && target_type != TYPE_BOOL) { return true; }
        let valid: Bool = true;
        if (target_type == TYPE_BOOL) {
            valid = float_value == 0.0 || float_value == 1.0;
        } else if (target_type == TYPE_CHAR) {
            valid = float_value >= 0.0 && float_value < 1114112.0 &&
                    (float_value < 55296.0 || float_value >= 57344.0);
        } else {
            let limit: Float = float_integer_limit(target_type);
            if (is_unsigned_integer(target_type)) {
                valid = float_value >= 0.0 && float_value < limit;
            } else {
                valid = float_value >= 0.0 - limit && float_value < limit;
            }
        }
        if (!valid) {
            throw_overflow_error(pos, "Constant " + literal_text + " overflows " + target_name);
            return false;
        }
        return true;
    }

    if (target_type == TYPE_BOOL) {
        if (negative || magnitude > UInt128(1)) {
            throw_type_error(pos, "Cannot convert constant " + literal_text + " to Bool; expected 0 or 1");
            return false;
        }
        return true;
    }
    if (target_type == TYPE_CHAR) {
        if (negative || magnitude > UInt128(1114111) ||
            (magnitude >= UInt128(55296) && magnitude <= UInt128(57343))) {
            throw_overflow_error(pos, "Constant " + literal_text + " is not a valid Unicode scalar value");
            return false;
        }
        return true;
    }
    if (!is_integer_type(target_type)) { return true; }

    if (!negative) {
        let max_value: UInt128 = positive_integer_limit(target_type);
        if (max_value != UInt128(0) && magnitude > max_value) {
            throw_overflow_error(pos, "Constant " + literal_text + " overflows " + target_name);
            return false;
        }
        return true;
    }

    if (is_unsigned_integer(target_type)) {
        throw_overflow_error(pos, "Constant " + literal_text + " overflows " + target_name);
        return false;
    }
    let limit: UInt128 = signed_negative_limit(target_type);
    if (limit != UInt128(0) && magnitude > limit) {
        throw_overflow_error(pos, "Constant " + literal_text + " overflows " + target_name);
        return false;
    }
    return true;
}

func c_vararg_type(ref c: Compiler, type_id: Int, pos: Position) -> Int {
// C's anonymous arguments undergo default promotions, the named prefix does not.
    let repr = get_repr_type(ref c, type_id);
    if (repr == TYPE_POISON) { return TYPE_POISON; }
    if (repr == TYPE_FLOAT32) { return TYPE_FLOAT; }
    if (repr == TYPE_BOOL || (is_integer_type(repr) && get_type_bitwidth(repr) < 32)) {
        return TYPE_INT;
    }
    if (repr >= 100 && !is_pointer_type(ref c, repr)) {
        throw_type_error(pos, "Cannot pass complex types (Struct/Array/Vector) directly to C varargs functions.");
        return TYPE_POISON;
    }
    return type_id;
}

func check_unary_operand(ref c: Compiler, op: Int, type_id: Int, pos: Position) -> Bool {
// validate source types before either backend chooses an instruction
    if (type_id == TYPE_POISON) { return false; }
    let repr = get_repr_type(ref c, type_id);
    let numeric = is_integer_type(repr) || repr == TYPE_FLOAT || repr == TYPE_FLOAT32;

    if (op == TOK_SUB && !numeric) {
        throw_type_error(pos, "Cannot negate non-numeric type.");
        return false;
    }
    if (op == TOK_PLUS && !numeric) {
        throw_type_error(pos, "Operator '+' requires a numeric type.");
        return false;
    }
    if (op == TOK_NOT && repr != TYPE_BOOL) {
        throw_type_error(pos, "Operator '!' requires Bool type.");
        return false;
    }
    if (op == TOK_BIT_NOT && !is_integer_type(repr)) {
        throw_type_error(pos, "Operator '~' requires an integer type.");
        return false;
    }

    return true;
}

func check_postfix_operand(ref c: Compiler, type_id: Int, pos: Position) -> Bool {
    if (type_id == TYPE_POISON) { return false; }
    let repr = get_repr_type(ref c, type_id);
    if (repr == TYPE_BOOL) {
        throw_type_error(pos, "Cannot increment/decrement Bool type.");
        return false;
    }
    if (!is_integer_type(repr) && repr != TYPE_FLOAT && repr != TYPE_FLOAT32) {
        throw_type_error(pos, "Cannot increment/decrement type " + get_type_name(ref c, type_id));
        return false;
    }

    return true;
}

func return_value_type(ref c: Compiler, return_type: Int) -> Int {
// literals and constructors need T as their context before the T? carrier is built
    if (is_fallible_type(ref c, return_type)) {
        return get_inner_fallible_type(ref c, return_type);
    }
    return return_type;
}

func check_null_return(ref c: Compiler, value_type: Int, return_type: Int, pos: Position) -> Bool {
// a fallible return still needs a valid success value, null never stands for an error
    if (value_type == TYPE_POISON) { return false; }
    let target = return_value_type(ref c, return_type);

    if (value_type == TYPE_NULLPTR && !is_pointer_type(ref c, target)) {
        throw_type_error(pos, "'nullptr' can only be returned for explicit pointer types.");
        return false;
    }
    if (value_type == TYPE_NULL) {
        if (union_member_index(ref c, target, TYPE_NULL) >= 0) { return true; }
        if (is_pointer_type(ref c, target)) {
            throw_type_error(pos, "'null' cannot be returned for explicit pointer types. Use 'nullptr'.");
            return false;
        }
        if (!is_nullable_reference_type(ref c, target)) {
            throw_type_error(pos, "Type " + get_type_name(ref c, target) + " cannot be null.");
            return false;
        }
    }

    return true;
}

func check_equality_operands(ref c: Compiler, left_repr: Int, right_repr: Int, pos: Position) -> Bool {
    if (left_repr == TYPE_NULL || left_repr == TYPE_NULLPTR || right_repr == TYPE_NULL || right_repr == TYPE_NULLPTR) {
        throw_type_error(pos, "Invalid operator. Do not use '==' or '!=' with null/nullptr. Use 'is' or 'is !'.");
        return false;
    }
    if (left_repr == TYPE_ANYPTR || right_repr == TYPE_ANYPTR ||
        (left_repr >= 100 && is_pointer_type(ref c, left_repr)) ||
        (right_repr >= 100 && is_pointer_type(ref c, right_repr))) {
        throw_type_error(pos, "Pointer addresses must be compared with 'is' or 'is !'.");
        return false;
    }
    return true;
}

func check_equality_fallback(ref c: Compiler, left_repr: Int, right_repr: Int, pos: Position) -> Bool {
// protocol dispatch has already failed, a class must not fall through to an address comparison
    let class_operand: Bool = left_repr == TYPE_GENERIC_CLASS || right_repr == TYPE_GENERIC_CLASS;
    if (left_repr >= 100) {
        let info: Optional(StructInfo) = c.struct_id_map.lookup(left_repr);
        class_operand = class_operand || ((info is !null) && info.is_class);
    }
    if (!class_operand && right_repr >= 100 && right_repr != left_repr) {
        let info: Optional(StructInfo) = c.struct_id_map.lookup(right_repr);
        class_operand = (info is !null) && info.is_class;
    }

    if class_operand {
        throw_type_error(pos, "Class equality requires matching types implementing Equal. Use 'is' or 'is !' for identity.");
        return false;
    }
    return true;
}

func check_identity_operand(ref c: Compiler, type_id: Int, pos: Position) -> Bool {
    if (type_id == TYPE_POISON) { return false; }
    if (type_id >= 100 && is_value_struct(ref c, type_id)) {
        throw_type_error(pos, "Operator 'is' is not defined for Struct values. Compare explicit pointers instead.");
        return false;
    }
    return true;
}

func register_extern_library(ref c: Compiler, name: String, pos: Position) -> Void {
    if (name.length() == 0) {
        return;
    }

    let i: Int = 0;
    while (i < name.length()) {
        let ch: Char = name[i];
        let valid: Bool = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
                          (ch >= '0' && ch <= '9') || ch == '_' || ch == '-' ||
                          ch == '+' || ch == '.';
        if (!valid) {
            throw_extern_error(pos, "Invalid extern library name '" + name + "'. Use a linker library name without paths or flags.");
            return;
        }
        i++;
    }

    i = 0;
    while (i < c.extra_libs.length()) {
        if (c.extra_libs[i] == name) {
            return;
        }
        i++;
    }
    c.extra_libs.append(name);
}

func expr_root_name(ref c: Compiler, node: NodeID) -> String {
    if (!has_node(node)) { return ""; }
    let base: Int = node_tag(node);
    if (base == NODE_VAR_ACCESS) {
        let value: VarAccessNode = get_var_access_node(ref c.arena, node);
        return value.name_tok.value;
    }
    if (base == NODE_FIELD_ACCESS) {
        let value: FieldAccessNode = get_field_access_node(ref c.arena, node);
        return expr_root_name(ref c, value.obj);
    }
    if (base == NODE_INDEX_ACCESS) {
        let value: IndexAccessNode = get_index_access_node(ref c.arena, node);
        return expr_root_name(ref c, value.target);
    }
    if (base == NODE_SLICE_ACCESS) {
        let value: SliceAccessNode = get_slice_access_node(ref c.arena, node);
        return expr_root_name(ref c, value.target);
    }
    if (base == NODE_DEREF) {
        let value: DerefNode = get_deref_node(ref c.arena, node);
        return expr_root_name(ref c, value.node);
    }
    return "";
}

func const_access_root(ref c: Compiler, node: NodeID) -> String {
    let name: String = expr_root_name(ref c, node);
    if (name.length() == 0) { return ""; }
    let info: Optional(SymbolInfo) = find_symbol(ref c, name);
    if ((info is !null) && (info.is_const || info.is_const_access)) { return name; }
    return "";
}

func reject_const_write(ref c: Compiler, node: NodeID, pos: Position) -> Bool {
    let name: String = const_access_root(ref c, node);
    if (name.length() == 0) { return false; }
    throw_type_error(pos, "Cannot modify value through const access '" + name + "'");
    return true;
}

func is_ref_binding_init(ref c: Compiler, node: NodeID) -> Bool {
    if (!has_node(node) || node_tag(node) != NODE_REF) { return false; }
    let reference: RefNode = get_ref_node(ref c.arena, node);
    return has_node(reference.node) && node_tag(reference.node) != NODE_SLICE_ACCESS;
}

func stable_ref_target(ref c: Compiler, node: NodeID) -> Bool {
    if (!has_node(node)) { return false; }
    let kind: Int = node_tag(node);
    if (kind == NODE_VAR_ACCESS) {
        let access: VarAccessNode = get_var_access_node(ref c.arena, node);
        return (find_symbol(ref c, access.name_tok.value) is !null);
    }
    if (kind == NODE_FIELD_ACCESS) {
        let access: FieldAccessNode = get_field_access_node(ref c.arena, node);
        let owner_type: Int = get_repr_type(ref c, get_expr_type(ref c, access.obj));
        if (is_pointer_type(ref c, owner_type)) { return false; }
        let owner: Optional(StructInfo) = c.struct_id_map.lookup(owner_type);
        return (owner is !null) && !owner.is_class && stable_ref_target(ref c, access.obj);
    }
    if (kind == NODE_INDEX_ACCESS) {
        let access: IndexAccessNode = get_index_access_node(ref c.arena, node);
        let target_type: Int = get_repr_type(ref c, get_expr_type(ref c, access.target));
        let array: Optional(ArrayInfo) = c.array_info_map.lookup(target_type);
        let vector = c.vector_base_map.lookup(target_type);
        let checked = c.ref_targets.contains_key(UInt32(node));
        return (((array is !null) && (array.size >= 0 || checked)) || ((vector is !null) && checked)) &&
               stable_ref_target(ref c, access.target);
    }
    return false;
}

func method_mutates_self(ref c: Compiler, node: NodeID) -> Bool {
    if (!has_node(node)) { return false; }
    let base: Int = node_tag(node);
    if (base == NODE_FIELD_ASSIGN) {
        let value: FieldAssignNode = get_field_assign_node(ref c.arena, node);
        return expr_root_name(ref c, value.obj) == "self" || expr_root_name(ref c, value.value) == "self";
    }
    if (base == NODE_INDEX_ASSIGN) {
        let value: IndexAssignNode = get_index_assign_node(ref c.arena, node);
        return expr_root_name(ref c, value.target) == "self" || expr_root_name(ref c, value.value) == "self";
    }
    if (base == NODE_PTR_ASSIGN) {
        let value: PtrAssignNode = get_ptr_assign_node(ref c.arena, node);
        return expr_root_name(ref c, value.pointer) == "self" || expr_root_name(ref c, value.value) == "self";
    }
    if (base == NODE_POSTFIX) {
        let value: PostfixOpNode = get_postfix_node(ref c.arena, node);
        return expr_root_name(ref c, value.node) == "self";
    }
    if (base == NODE_REF) {
        let value: RefNode = get_ref_node(ref c.arena, node);
        return expr_root_name(ref c, value.node) == "self";
    }
    if (base == NODE_VAR_DECL) {
        let value: VarDeclareNode = get_var_decl_node(ref c.arena, node);
        return expr_root_name(ref c, value.value) == "self";
    }
    if (base == NODE_VAR_ASSIGN) {
        let value: VarAssignNode = get_var_assign_node(ref c.arena, node);
        return expr_root_name(ref c, value.value) == "self";
    }
    if (base == NODE_CALL) {
        let call: CallNode = get_call_node(ref c.arena, node);
        let callee: Int = node_tag(call.callee);
        if (callee == NODE_FIELD_ACCESS) {
            let field: FieldAccessNode = get_field_access_node(ref c.arena, call.callee);
            if (expr_root_name(ref c, field.obj) == "self") { return true; }
        }
        let i: Int = 0;
        while (i < call.args.length()) {
            let arg: ArgNode = call.args[i];
            if (expr_root_name(ref c, arg.val) == "self") { return true; }
            i += 1;
        }
    }
    if (base == NODE_FUNC_DEF) {
        let value: FunctionDefNode = get_func_def_node(ref c.arena, node);
        return method_mutates_self(ref c, value.body);
    }
    if (base == NODE_BLOCK) {
        let block: BlockNode = get_block_node(ref c.arena, node);
        let i: Int = 0;
        while (i < block.stmts.length()) {
            if (method_mutates_self(ref c, block.stmts[i])) { return true; }
            i += 1;
        }
    }
    if (base == NODE_IF) {
        let value: IfNode = get_if_node(ref c.arena, node);
        return method_mutates_self(ref c, value.body) || method_mutates_self(ref c, value.else_body);
    }
    if (base == NODE_WHILE) {
        let value: WhileNode = get_while_node(ref c.arena, node);
        return method_mutates_self(ref c, value.body);
    }
    if (base == NODE_FOR) {
        let value: ForNode = get_for_node(ref c.arena, node);
        return method_mutates_self(ref c, value.init) || method_mutates_self(ref c, value.step) || method_mutates_self(ref c, value.body);
    }
    if (base == NODE_CATCH) {
        let value: CatchNode = get_catch_node(ref c.arena, node);
        return method_mutates_self(ref c, value.stmt) || method_mutates_self(ref c, value.body);
    }
    return false;
}

func check_duplicate_params(params: Vector(ParamNode), owner: String, pos: Position) -> Bool {
    let seen: Dict(String, StringConstant) = Dict();
    let i: Int = 0;
    while (i < params.length()) {
        let param: ParamNode = params[i];
        let name: String = param.name_tok.value;
        if (seen.contains_key(name)) {
            throw_name_error(param.pos, "Duplicate parameter '" + name + "' in " + owner);
            return false;
        }
        seen.put(name, StringConstant(id=0, value=name));
        i += 1;
    }
    return true;
}

func same_method_signature(parent: FuncInfo, child: FuncInfo) -> Bool {
    if (!has_func(parent) || !has_func(child) || parent.ret_type != child.ret_type) { return false; }
    let parent_len: Int = parent.arg_types.length();
    let child_len: Int = child.arg_types.length();
    if (parent_len != child_len) { return false; }
    let i: Int = 1;
    while (i < parent_len) {
        let a: TypeListNode = parent.arg_types[i];
        let b: TypeListNode = child.arg_types[i];
        if (a.type != b.type || a.pass_mode != b.pass_mode) { return false; }
        i += 1;
    }
    return true;
}

func add_interface_type(ref c: Compiler, list: Vector(Struct), type_id: Int, pos: Position) -> Bool {
    if (type_id == TYPE_POISON) { return false; }
    let info: Optional(StructInfo) = c.struct_id_map.lookup(type_id);
    if (!(info is !null) || !info.is_interface) {
        throw_type_error(pos, "Type " + get_type_name(ref c, type_id) + " is not an interface.");
        return false;
    }
    let meta_info: StructInfo = info;
    let parent_index: Int = 0;
    while (parent_index < meta_info.interfaces.length()) {
        let parent: TypeListNode = meta_info.interfaces[parent_index];
        if (!add_interface_type(ref c, list, parent.type, pos)) { return false; }
        parent_index += 1;
    }
    let i: Int = 0;
    while (i < list.length()) {
        let item: TypeListNode = list[i];
        if (item.type == type_id) { return true; }
        i++;
    }
    list.append(TypeListNode(type=type_id, pass_mode=0));
    return true;
}

func add_interface(ref c: Compiler, list: Vector(Struct), node: NodeID, pos: Position) -> Bool {
    return add_interface_type(ref c, list, resolve_type(ref c, node), pos);
}

func class_has_interface(ref c: Compiler, class_info: StructInfo, target: StructInfo) -> Bool {
    let current: Optional(StructInfo) = class_info;
    while ((current is !null)) {
        let info: StructInfo = current;
        let i: Int = 0;
        while (i < info.interfaces.length()) {
            let item: TypeListNode = info.interfaces[i];
            if (item.type == target.type_id) { return true; }
            i += 1;
        }
        if (info.parent_id == 0) {
            break;
        }
        current = c.struct_id_map.lookup(info.parent_id);
    }
    return false;
}

func is_unsuffix_int_literal(ref c: Compiler, node: NodeID) -> Bool {
    if (!has_node(node)) { return false; }
    let base: Int = node_tag(node);
    if (base != NODE_INT) { return false; }
    let value: IntNode = get_int_node(ref c.arena, node);
    let text: String = value.tok.value;
    return !text.ends_with("u") && !text.ends_with("U") && !text.ends_with("ul") && !text.ends_with("UL") && !text.ends_with("ull") && !text.ends_with("ULL");
}

func bind_call_args(args: Vector(ArgNode), names: Vector(String), skip: Int, pos: Position) -> Optional(Vector(ArgNode)) {
    let expected: Int = names.length() - skip;
    let count: Int = args.length();
    if (count != expected) {
        throw_type_error(pos, "Expected " + expected + " arguments, got " + count);
        return null;
    }
    let ordered: Vector(ArgNode) = [];
    let i: Int = 0;
    while (i < expected) {
        ordered.append(ArgNode(val=NO_NODE, name="", is_spread=false));
        i += 1;
    }
    let next_positional: Int = 0;
    let saw_named: Bool = false;
    i = 0;
    while (i < count) {
        let arg: ArgNode = args[i];
        if (arg.is_spread) {
            throw_invalid_syntax(pos, "A spread argument requires a variadic parameter.");
            return null;
        }
        let target: Int = -1;
        if (arg.name.length() == 0) {
            if saw_named {
                throw_invalid_syntax(pos, "Positional argument cannot follow a named argument");
                return null;
            }
            target = next_positional;
            next_positional += 1;
        } else {
            saw_named = true;
            let name_index: Int = skip;
            while (name_index < names.length()) {
                if (names[name_index] == arg.name) {
                    target = name_index - skip;
                    break;
                }
                name_index += 1;
            }

            if (target < 0) {
                throw_name_error(pos, "Unknown argument '" + arg.name + "'");
                return null;
            }
        }
        if (target < 0 || target >= expected) {
            throw_type_error(pos, "Too many arguments");
            return null;
        }
        if (has_node(ordered[target].val)) {
            let duplicate: String = names[target + skip];
            throw_name_error(pos, "Argument '" + duplicate + "' is specified more than once");
            return null;
        }
        ordered[target] = arg;
        i += 1;
    }

    i = 0;
    while (i < expected) {
        if (!has_node(ordered[i].val)) {
            throw_type_error(pos, "Missing argument '" + names[i + skip] + "'");
            return null;
        }
        i += 1;
    }
    return ordered;
}

func bind_native_args(args: Vector(ArgNode), info: FuncInfo, skip: Int, pos: Position) -> BoundCallArgs {
    let names: Vector(String) = info.arg_names;
    let expected: Int = names.length() - skip;
    let pack_index: Int = info.variadic_param - 1;
    let ordered: Vector(ArgNode) = [];
    let packed: Vector(ArgNode) = [];

    let i: Int = 0;
    while (i < expected) {
        ordered.append(ArgNode(val=NO_NODE, name="", is_spread=false));
        i += 1;
    }

    let next_positional: Int = 0;
    let saw_named: Bool = false;

    i = 0;
    while (i < args.length()) {
        let arg: ArgNode = args[i];
        if (arg.name.length() == 0) {
            if saw_named {
                throw_invalid_syntax(pos, "Positional argument cannot follow a named argument.");
                return BoundCallArgs(valid=false, ordered=[], variadic=[]);
            }
            if (pack_index >= 0 && next_positional >= pack_index) {
                packed.append(arg);
                next_positional = pack_index;
            } else {
                if (arg.is_spread) {
                    throw_invalid_syntax(pos, "A spread argument requires a variadic parameter.");
                    return BoundCallArgs(valid=false, ordered=[], variadic=[]);
                }
                if (next_positional >= expected) {
                    throw_type_error(pos, "Too many arguments.");
                    return BoundCallArgs(valid=false, ordered=[], variadic=[]);
                }
                ordered[next_positional] = arg;
                next_positional += 1;
            }
        } else {
            saw_named = true;
            let target: Int = -1;
            let name_index: Int = skip;
            while (name_index < names.length()) {
                if (names[name_index] == arg.name) {
                    target = name_index - skip;
                    break;
                }
                name_index += 1;
            }
            if (target < 0) {
                throw_name_error(pos, "Unknown argument '" + arg.name + "'.");
                return BoundCallArgs(valid=false, ordered=[], variadic=[]);
            }
            if (target == pack_index) {
                throw_type_error(pos, "Variadic parameter '" + arg.name + "' must be supplied with positional arguments.");
                return BoundCallArgs(valid=false, ordered=[], variadic=[]);
            }
            if (has_node(ordered[target].val)) {
                throw_name_error(pos, "Argument '" + arg.name + "' is specified more than once.");
                return BoundCallArgs(valid=false, ordered=[], variadic=[]);
            }
            ordered[target] = arg;
        }
        i += 1;
    }

    i = 0;
    while (i < expected) {
        if (i == pack_index) {
            i += 1;
            continue;
        }
        if (!has_node(ordered[i].val)) {
            let default_index: Int = i;
            if (default_index < info.default_args.length() && has_node(info.default_args[default_index])) {
                ordered[i] = ArgNode(val=info.default_args[default_index], name=names[i + skip], is_spread=false);
            } else {
                throw_type_error(pos, "Missing argument '" + names[i + skip] + "'.");
                return BoundCallArgs(valid=false, ordered=[], variadic=[]);
            }
        }
        i += 1;
    }
    return BoundCallArgs(ordered=ordered, variadic=packed, valid=true);
}

func validate_callable_value(info: FuncInfo, skip: Int, pos: Position, kind: String) -> Bool {
    if (info.is_varargs) {
        throw_type_error(pos, "A C variadic function cannot be used as a White Language " + kind + " value.");
        return false;
    }
    return true;
}

func callable_types_compatible(ref c: Compiler, actual: Int, expected: Int) -> Bool {
    let actual_info: Optional(SymbolInfo) = c.func_ret_map.lookup(actual);
    let expected_info: Optional(SymbolInfo) = c.func_ret_map.lookup(expected);
    if (!(actual_info is !null) || !(expected_info is !null)) {
        actual_info = c.method_ret_map.lookup(actual);
        expected_info = c.method_ret_map.lookup(expected);
    }
    if (!(actual_info is !null) || !(expected_info is !null)) { return false; }
    let meta_actual_info: SymbolInfo = actual_info;
    let meta_expected_info: SymbolInfo = expected_info;
    if (meta_actual_info.type != expected_info.type || meta_actual_info.variadic_param != expected_info.variadic_param) {
        return false;
    }
    if (meta_actual_info.func_arg_types.length() != expected_info.func_arg_types.length()) { return false; }

    let i: Int = 0;
    while (i < meta_actual_info.func_arg_types.length()) {
        let actual_arg: TypeListNode = meta_actual_info.func_arg_types[i];
        let expected_arg: TypeListNode = meta_expected_info.func_arg_types[i];
        if (actual_arg.type != expected_arg.type || actual_arg.pass_mode != expected_arg.pass_mode) {
            return false;
        }
        i += 1;
    }
    return true;
}

func bind_callable_args(args: Vector(ArgNode), signature: SymbolInfo, pos: Position) -> BoundCallArgs {
    let expected: Int = signature.func_arg_types.length();
    let count: Int = args.length();
    let pack_index: Int = signature.variadic_param - 1;
    let ordered: Vector(ArgNode) = [];
    let packed: Vector(ArgNode) = [];

    if (pack_index < 0) {
        if (reject_named_args(args, pos, "a Function or Method value")) {
            return BoundCallArgs(valid=false, ordered=[], variadic=[]);
        }
        if (count != expected) {
            throw_type_error(pos, "Argument count mismatch in Function or Method call. Expected " + expected + ", got " + count + ".");
            return BoundCallArgs(valid=false, ordered=[], variadic=[]);
        }
        let i: Int = 0;
        while (i < count) {
            let arg: ArgNode = args[i];
            if (arg.is_spread) {
                throw_invalid_syntax(pos, "A spread argument requires a variadic callable type.");
                return BoundCallArgs(valid=false, ordered=[], variadic=[]);
            }
            ordered.append(arg);
            i += 1;
        }
        return BoundCallArgs(ordered=ordered, variadic=packed, valid=true);
    }

    let i: Int = 0;
    while (i < expected) {
        ordered.append(ArgNode(val=NO_NODE, name="", is_spread=false));
        i += 1;
    }

    let next_positional: Int = 0;
    let saw_named: Bool = false;

    i = 0;
    while (i < count) {
        let arg: ArgNode = args[i];
        if (arg.name.length() == 0) {
            if saw_named {
                throw_invalid_syntax(pos, "Positional argument cannot follow a named argument.");
                return BoundCallArgs(valid=false, ordered=[], variadic=[]);
            }
            if (next_positional < pack_index) {
                if (arg.is_spread) {
                    throw_invalid_syntax(pos, "A spread argument cannot replace a fixed callable argument.");
                    return BoundCallArgs(valid=false, ordered=[], variadic=[]);
                }
                ordered[next_positional] = arg;
                next_positional += 1;
            } else {
                packed.append(arg);
                next_positional = pack_index;
            }
        } else {
            saw_named = true;
            let target: Int = -1;
            let name_index: Int = pack_index + 1;
            while (name_index < expected) {
                if (name_index < signature.arg_names.length() && signature.arg_names[name_index] == arg.name) {
                    target = name_index;
                    break;
                }
                name_index += 1;
            }
            if (target < 0) {
                throw_name_error(pos, "Unknown callable argument '" + arg.name + "'.");
                return BoundCallArgs(valid=false, ordered=[], variadic=[]);
            }
            if (has_node(ordered[target].val)) {
                throw_name_error(pos, "Argument '" + arg.name + "' is specified more than once.");
                return BoundCallArgs(valid=false, ordered=[], variadic=[]);
            }
            ordered[target] = arg;
        }
        i += 1;
    }

    i = 0;
    while (i < expected) {
        if (i != pack_index && !has_node(ordered[i].val)) {
            let name: String = "";
            if (i < signature.arg_names.length()) {
                name = signature.arg_names[i];
            }
            if (name.length() > 0) {
                throw_type_error(pos, "Missing callable argument '" + name + "'.");
            }
            else {
                throw_type_error(pos, "Missing positional argument " + (i + 1) + " in Function or Method call.");
            }
            return BoundCallArgs(valid=false, ordered=[], variadic=[]);
        }
        i += 1;
    }
    return BoundCallArgs(ordered=ordered, variadic=packed, valid=true);
}

func reject_named_args(args: Vector(ArgNode), pos: Position, target: String) -> Bool {
    let i: Int = 0;
    while (i < args.length()) {
        let arg: ArgNode = args[i];
        if (arg.name.length() != 0) {
            throw_invalid_syntax(pos, "Named arguments are not available when calling " + target);
            return true;
        }
        i += 1;
    }
    return false;
}

func reject_spread_args(args: Vector(ArgNode), pos: Position, target: String) -> Bool {
    let i: Int = 0;
    while (i < args.length()) {
        let arg: ArgNode = args[i];
        if (arg.is_spread) {
            throw_invalid_syntax(pos, "Argument expansion is not available when calling " + target + ".");
            return true;
        }
        i += 1;
    }
    return false;
}
