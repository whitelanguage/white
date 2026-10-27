// src/compiler/type_tests.wl
import * from "context.wl"
import * from "../frontend/ast.wl"
import * from "../frontend/arena.wl"
import * from "../frontend/diagnostics.wl"


func type_test_kind(ref c: Compiler, node: NodeID) -> Int {
// aliases keep the intrinsic identity, a local callable may shadow its public name
    if (!has_node(node) || node_tag(node) != NODE_CALL) { return 0; }
    let call = get_call_node(ref c.arena, node);
    if (node_tag(call.callee) == NODE_VAR_ACCESS) {
        let name = get_var_access_node(ref c.arena, call.callee).name_tok.value;
        if (find_symbol(ref c, name) is !null) { return 0; }
        let local = c.func_table.lookup(c.current_package_prefix + name);
        if ((local is !null) && (local.ann_flags & FLAG_ANN_INTRINSIC) == 0) { return 0; }
    }
    let name = generic_symbol_name(ref c, call.callee, true);
    let info = c.func_table.lookup(name);
    if (info is null || (info.ann_flags & FLAG_ANN_INTRINSIC) == 0) { return 0; }
    if (info.base_name == "is_type") { return 1; }
    if (info.base_name == "is_instance") { return 2; }
    return 0;
}

func type_test_operand(ref c: Compiler, node: NodeID, pos: Position) -> NodeID {
// call syntax in a type operand denotes an instantiated type, it never constructs a value
    let kind = node_tag(node);
    if (kind == NODE_CALL) {
        let call = get_call_node(ref c.arena, node);
        if (call.type_args.length() != 0) {
            throw_type_error(pos, "The second argument to a type check must be a type, got a value.");
            return NO_NODE;
        }
        let args: Vector(NodeID) = [];
        let i = 0;
        while (i < call.args.length()) {
            if (call.args[i].name.length() != 0 || call.args[i].is_spread) {
                throw_type_error(pos, "The second argument to a type check must be a type, got a value.");
                return NO_NODE;
            }
            let arg = type_test_operand(ref c, call.args[i].val, pos);
            if (!has_node(arg)) { return NO_NODE; }
            args.append(arg);
            i++;
        }
        return add_generic_type_node(ref c.arena, GenericTypeNode(type=NODE_GENERIC_TYPE, base_type=call.callee, type_args=args, pos=pos));
    }
    if (kind == NODE_INDEX_ACCESS) {
        let array = get_index_access_node(ref c.arena, node);
        if (node_tag(array.index_node) != NODE_INT) {
            throw_type_error(pos, "An array type requires a constant integer size.");
            return NO_NODE;
        }
        let base = type_test_operand(ref c, array.target, pos);
        if (!has_node(base)) { return NO_NODE; }
        return add_array_type_node(ref c.arena, ArrayTypeNode(type=NODE_ARRAY_TYPE, base_type=base, size_tok=get_int_node(ref c.arena, array.index_node).tok, pos=pos));
    }
    if (kind == NODE_VAR_ACCESS) {
        let name = get_var_access_node(ref c.arena, node).name_tok.value;
        if (find_symbol(ref c, name) is null) { return node; }
    } else if (kind == NODE_FIELD_ACCESS || kind == NODE_GENERIC_TYPE || kind == NODE_PTR_TYPE ||
        kind == NODE_ARRAY_TYPE || kind == NODE_VECTOR_TYPE || kind == NODE_FUNCTION_TYPE || kind == NODE_METHOD_TYPE) {
        return node;
    }
    throw_type_error(pos, "The second argument to a type check must be a type, got a value.");
    return NO_NODE;
}

func type_test_target(ref c: Compiler, call: CallNode) -> Int {
    if (call.args.length() != 2 || call.type_args.length() != 0) {
        throw_type_error(call.pos, "Type checks require a value followed by a type, expected 2 arguments.");
        return TYPE_POISON;
    }
    let i = 0;
    while (i < call.args.length()) {
        if (call.args[i].name.length() != 0 || call.args[i].is_spread) {
            throw_type_error(call.pos, "Type checks do not accept named or spread arguments.");
            return TYPE_POISON;
        }
        i++;
    }
    let node = type_test_operand(ref c, call.args[1].val, call.pos);
    if (!has_node(node)) { return TYPE_POISON; }
    if (node != call.args[1].val) {
        call.args[1] = ArgNode(val=node, name="", is_spread=false);
    }
    let target = resolve_type(ref c, node);
    if (target == TYPE_VOID || target == TYPE_AUTO || target == TYPE_GENERIC_CLASS ||
        target == TYPE_GENERIC_STRUCT || target == TYPE_GENERIC_FUNCTION || target == TYPE_GENERIC_METHOD ||
        is_union_type(ref c, target) || is_fallible_type(ref c, target)) {
        throw_type_error(call.pos, "Type checks require a concrete type.");
        return TYPE_POISON;
    }
    return target;
}

func type_test_class(ref c: Compiler, type_id: Int) -> Bool {
    if (type_id == TYPE_GENERIC_CLASS) { return true; }
    let info = c.struct_id_map.lookup(get_repr_type(ref c, type_id));
    return (info is !null) && (info.is_class || info.is_interface);
}

func type_test_header(type_id: Int) -> Bool {
    return type_id == TYPE_GENERIC_STRUCT || type_id == TYPE_GENERIC_FUNCTION || type_id == TYPE_GENERIC_METHOD;
}

func check_instance_types(ref c: Compiler, source: Int, target: Int, pos: Position) -> Bool {
    let info = c.struct_id_map.lookup(target);
    if (info is null || !info.is_class) {
        throw_type_error(pos, "The second argument to is_instance must be a class type.");
        return false;
    }
    let found = get_union_type(ref c, source);
    if (found is !null) {
        let union: UnionInfo = found;
        let i = 0;
        while (i < union.members.length()) {
            let member = union.members[i];
            if (member != TYPE_NULL && !type_test_class(ref c, member)) {
                throw_type_error(pos, "is_instance requires a class instance, got " + get_type_name(ref c, member) + ".");
                return false;
            }
            i++;
        }
        return true;
    }
    if (source != TYPE_NULL && !type_test_class(ref c, source)) {
        throw_type_error(pos, "is_instance requires a class instance, got " + get_type_name(ref c, source) + ".");
        return false;
    }
    return true;
}

func type_test_matches(ref c: Compiler, source: Int, target: Int, instance: Bool) -> Bool {
    if (source == target) { return true; }
    return instance && type_test_class(ref c, source) && is_subclass(ref c, source, target);
}
