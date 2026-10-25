// src/compiler/narrowing.wl
import * from "context.wl"
import * from "../frontend/ast.wl"
import * from "../frontend/arena.wl"
import * from "../frontend/tokens.wl"


struct FlowGuard(target: NodeID, present: Bool)

func flow_apply_guard(ref c: Compiler, condition: NodeID, truth: Bool) -> Void {
// resolve the declared union before recording its checked member
    if (!flow_has_guard(ref c, condition)) { return; }
    let guards: Vector(FlowGuard) = [];
    flow_guards(ref c, condition, truth, guards);
    let i = 0;
    while (i < guards.length()) {
        let guard = guards[i];
        let old_skip = c.flow_skip;
        c.flow_skip = guard.target;
        let original = get_expr_type(ref c, guard.target);
        c.flow_skip = old_skip;
        let path = format_ast_path(ref c, guard.target);
        let root = path;
        let dot = 0;
        while (dot < root.length() && root[dot] != Byte(46)) { dot++; }
        if (dot < root.length()) { root = root.slice(0, dot); }
        let symbol = find_symbol(ref c, root);
        let unstable = flow_has_field(path) || !(symbol is !null);
        if ((symbol is !null)) { unstable = unstable || symbol.reg.starts_with("@") || symbol.is_reference; }
        unstable = unstable || flow_is_exposed(ref c, path);
        if (!unstable || !flow_has_call(ref c, condition)) {
            flow_record(ref c, guard.target, original, guard.present, unstable);
        }
        i++;
    }
}

func flow_write_facts(ref c: Compiler, node: NodeID) -> Vector(FlowType) {
// an inline field address remains valid only while each enclosing union keeps its arm
    let result: Vector(FlowType) = [];
    let current = node;
    while (has_node(current)) {
        let member = flow_type(ref c, current);
        let type_id = member;
        if (type_id == 0) { type_id = get_expr_type(ref c, current); }
        let owner: Optional(StructInfo) = c.struct_id_map.lookup(get_repr_type(ref c, type_id));
        if (((owner is !null) && owner.is_class) || is_pointer_type(ref c, type_id)) { break; }
        if (member != 0) {
            result.append(FlowType(path=format_ast_path(ref c, current), type=member, unstable=false));
        }
        if (node_tag(current) != NODE_FIELD_ACCESS) { break; }
        current = get_field_access_node(ref c.arena, current).obj;
    }
    return result;
}

func flow_write_valid(ref c: Compiler, facts: Vector(FlowType)) -> Bool {
    let i = 0;
    while (i < facts.length()) {
        let found = false;
        let j = 0;
        while (j < c.flow_types.length()) {
            if (facts[i].path == c.flow_types[j].path && facts[i].type == c.flow_types[j].type) {
                found = true;
                break;
            }
            j++;
        }
        if (!found) { return false; }
        i++;
    }
    return true;
}

func flow_has_field(path: String) -> Bool {
    let i = 0;
    while (i < path.length()) {
        if (path[i] == Byte(46)) { return true; }
        i++;
    }
    return false;
}

func flow_copy(values: Vector(FlowType)) -> Vector(FlowType) {
    if (values.length() == 0) { return []; }
    let result: Vector(FlowType) = [];
    let i = 0;
    while (i < values.length()) {
        result.append(values[i]);
        i++;
    }
    return result;
}

func flow_forget(ref c: Compiler, path: String, call: Bool) -> Void {
// mutating a field may also change the same object through another local alias
    let result: Vector(FlowType) = [];
    let i = 0;
    while (i < c.flow_types.length()) {
        let fact: FlowType = c.flow_types[i];
        let remove = call && fact.unstable;
        if (!call && (fact.path == path || fact.path.starts_with(path + "."))) { remove = true; }
        if (!call && flow_has_field(path) && flow_has_field(fact.path)) { remove = true; }
        if (!remove) { result.append(fact); }
        i++;
    }
    c.flow_types = result;
}

func flow_is_exposed(ref c: Compiler, path: String) -> Bool {
    let i = 0;
    while (i < c.flow_exposed.length()) {
        if (path == c.flow_exposed[i] || path.starts_with(c.flow_exposed[i] + ".")) { return true; }
        i++;
    }
    return false;
}

func flow_expose(ref c: Compiler, node: NodeID) -> Void {
    let path = format_ast_path(ref c, node);
    if (path.starts_with("<unknown_path>")) {
        c.flow_types = [];
        return;
    }
    c.flow_exposed.append(path);
    flow_forget(ref c, path, false);
}

func flow_record(ref c: Compiler, target: NodeID, type_id: Int, present: Bool, unstable: Bool) -> Void {
    let found_union: Optional(UnionInfo) = get_union_type(ref c, get_repr_type(ref c, type_id));
    if (found_union is null || union_member_index(ref c, type_id, TYPE_NULL) < 0) { return; }
    let union: UnionInfo = found_union;
    let member: Int = TYPE_NULL;
    if present {
        // one surviving arm has a concrete read type, larger unions stay unions.
        if (union.members.length() != 2) { return; }
        member = union.members[0];
        if (member == TYPE_NULL) { member = union.members[1]; }
    }
    let path = format_ast_path(ref c, target);
    if (path.starts_with("<unknown_path>")) { return; }
    let i = 0;
    while (i < c.flow_types.length()) {
        if (c.flow_types[i].path == path) {
            c.flow_types[i] = FlowType(path=path, type=member, unstable=unstable || flow_is_exposed(ref c, path));
            return;
        }
        i++;
    }
    c.flow_types.append(FlowType(path=path, type=member, unstable=unstable || flow_is_exposed(ref c, path)));
}

func flow_has_call(ref c: Compiler, node: NodeID) -> Bool {
// a later operand can invalidate an earlier check in a compound condition
    if (!has_node(node)) { return false; }
    let kind = node_tag(node);
    if (kind == NODE_CALL || kind == NODE_REF || kind == NODE_VAR_ASSIGN || kind == NODE_FIELD_ASSIGN) { return true; }
    if (kind == NODE_BINOP || kind == NODE_IS || kind == NODE_IS_NOT) {
        let bin = get_binop_node(ref c.arena, node);
        return flow_has_call(ref c, bin.left) || flow_has_call(ref c, bin.right);
    }
    if (kind == NODE_UNARYOP) { return flow_has_call(ref c, get_unary_node(ref c.arena, node).node); }
    if (kind == NODE_TRY_UNWRAP) { return flow_has_call(ref c, get_try_unwrap_node(ref c.arena, node).expr); }
    return false;
}

func flow_has_guard(ref c: Compiler, node: NodeID) -> Bool {
    if (!has_node(node)) { return false; }
    let kind = node_tag(node);
    if (kind == NODE_IS || kind == NODE_IS_NOT) { return true; }
    if (kind == NODE_UNARYOP) { return flow_has_guard(ref c, get_unary_node(ref c.arena, node).node); }
    if (kind == NODE_BINOP) {
        let bin = get_binop_node(ref c.arena, node);
        return flow_has_guard(ref c, bin.left) || flow_has_guard(ref c, bin.right);
    }
    return false;
}

func flow_intersect(left: Vector(FlowType), right: Vector(FlowType)) -> Vector(FlowType) {
// only facts reaching the join along every live edge survive
    if (left.length() == 0 || right.length() == 0) { return []; }
    let result: Vector(FlowType) = [];
    let i = 0;
    while (i < left.length()) {
        let j = 0;
        while (j < right.length()) {
            if (left[i].path == right[j].path && left[i].type == right[j].type) {
                result.append(FlowType(path=left[i].path, type=left[i].type, unstable=left[i].unstable || right[j].unstable));
                break;
            }
            j++;
        }
        i++;
    }
    return result;
}

func flow_guards(ref c: Compiler, node: NodeID, truth: Bool, result: Vector(FlowGuard)) -> Void {
    if (!has_node(node)) { return; }
    let kind = node_tag(node);
    if (kind == NODE_UNARYOP) {
        let unary = get_unary_node(ref c.arena, node);
        if (unary.op_tok.type == TOK_NOT) { flow_guards(ref c, unary.node, !truth, result); }
        return;
    }
    if (kind == NODE_BINOP) {
        let bin = get_binop_node(ref c.arena, node);
        if ((bin.op_tok.type == TOK_AND && truth) || (bin.op_tok.type == TOK_OR && !truth)) {
            flow_guards(ref c, bin.left, truth, result);
            flow_guards(ref c, bin.right, truth, result);
        }
        return;
    }
    if (kind != NODE_IS && kind != NODE_IS_NOT) { return; }
    let bin = get_binop_node(ref c.arena, node);
    let target = bin.left;
    if (node_tag(bin.left) == NODE_NULL) { target = bin.right; }
    else if (node_tag(bin.right) != NODE_NULL) { return; }
    let present = truth;
    if (kind == NODE_IS) { present = !truth; }
    result.append(FlowGuard(target=target, present=present));
}
