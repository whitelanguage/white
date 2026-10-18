// src/compiler/references.wl
import * from "../frontend/ast.wl"
import * from "../frontend/arena.wl"
import * from "../frontend/diagnostics.wl"
import * from "context.wl"
import * from "target_eval.wl"


struct RefUse(name: String, owner: Int)
struct RefCheck(active: Vector(RefUse), parents: Vector(Int), escaped: Vector(Bool), slots: Dict(String, Int), allocations: Dict(UInt32, Int), collecting: Bool)

func ref_group(ref state: RefCheck, group: Int) -> Int {
    let root = group;
    while (state.parents[root] != root) { root = state.parents[root]; }
    while (group != root) {
        let next = state.parents[group];
        state.parents[group] = root;
        group = next;
    }
    return root;
}

func ref_join(ref state: RefCheck, left: Int, right: Int) -> Void {
// assignments join possible owners before validation, including assignments on loop backedges
    left = ref_group(ref state, left);
    right = ref_group(ref state, right);
    if (left == right) { return; }
    if (left < right) {
        state.parents[right] = left;
        state.escaped[left] = state.escaped[left] || state.escaped[right];
    } else {
        state.parents[left] = right;
        state.escaped[right] = state.escaped[right] || state.escaped[left];
    }
}

func ref_publish(ref state: RefCheck, owner: Int) -> Void {
// passing a Vector by value can expose its allocation, it cannot replace the caller's binding
    state.escaped[ref_group(ref state, owner)] = true;
}

func ref_allocation(ref state: RefCheck, node: NodeID) -> Int {
    let key = UInt32(node);
    if (state.allocations.contains_key(key)) { return state.allocations.lookup(key); }
    let group = state.parents.length();
    state.parents.append(group);
    state.escaped.append(false);
    state.allocations.put(key, group);
    return group;
}

func ref_owner(ref c: Compiler, ref state: RefCheck, node: NodeID) -> Int {
// zero covers parameters, fields and call results whose allocation identity is unknown
    if (!has_node(node)) { return 0; }
    let kind = node_tag(node);
    if (kind == NODE_VECTOR_LIT) { return ref_allocation(ref state, node); }
    if (kind == NODE_VAR_ACCESS) {
        let name = get_var_access_node(ref c.arena, node).name_tok.value;
        let symbol = find_symbol(ref c, name);
        if (has_symbol(symbol) && state.slots.contains_key(symbol.reg)) {
            return ref_group(ref state, state.slots.lookup(symbol.reg));
        }
    }
    if (kind == NODE_REF) { return ref_owner(ref c, ref state, get_ref_node(ref c.arena, node).node); }
    return 0;
}

func ref_conflict(ref state: RefCheck, owner: Int, pos: Position, operation: String) -> Void {
    owner = ref_group(ref state, owner);
    let i = 0;
    while (i < state.active.length()) {
        let use = state.active[i];
        let active_owner = ref_group(ref state, use.owner);
        if (owner == active_owner || (owner == 0 && state.escaped[active_owner]) ||
            (active_owner == 0 && state.escaped[owner])) {
            throw_type_error(pos, "Cannot " + operation + " while element reference '" + use.name + "' is active.");
            return;
        }
        i++;
    }
}

func ref_plain_drop(ref c: Compiler, type_id: Int, depth: Int) -> Bool {
// independent storage may still run user code when its last class element is dropped
    if (depth > 16) { return false; }
    type_id = get_repr_type(ref c, type_id);
    if (type_id == TYPE_STRING || !needs_drop(ref c, type_id)) { return true; }
    let vector: SymbolInfo = c.vector_base_map.lookup(type_id);
    if (has_symbol(vector)) { return ref_plain_drop(ref c, vector.type, depth + 1); }
    let array: ArrayInfo = c.array_info_map.lookup(type_id);
    if (has_array_info(array)) { return ref_plain_drop(ref c, array.base_type, depth + 1); }
    let record: StructInfo = c.struct_id_map.lookup(type_id);
    if (!has_struct(record) || record.is_class || record.is_interface) { return false; }
    let i = 0;
    while (i < record.fields.length()) {
        let field: FieldInfo = record.fields[i];
        if (!ref_plain_drop(ref c, field.type, depth + 1)) { return false; }
        i++;
    }
    return true;
}

func has_index_refs(ref c: Compiler) -> Bool {
// skip the extra body walk in files which only use stable slots or explicit pointers
    if (c.ref_files is null) {
        c.ref_files = Dict();
        c.ref_targets = Dict();
        c.ref_scan = 0;
    }

    while (c.ref_scan < c.arena.var_decl_nodes.length()) {
        let declaration = c.arena.var_decl_nodes[c.ref_scan];
        c.ref_scan++;
        if (!has_node(declaration.value) || node_tag(declaration.value) != NODE_REF) { continue; }
        if (has_node(declaration.type_node) && node_tag(declaration.type_node) == NODE_PTR_TYPE) { continue; }
        if (has_node(declaration.type_node) && node_tag(declaration.type_node) == NODE_VAR_ACCESS &&
            get_var_access_node(ref c.arena, declaration.type_node).name_tok.value == "AnyPtr") { continue; }
        let target = get_ref_node(ref c.arena, declaration.value).node;
        if (has_node(target) && node_tag(target) == NODE_INDEX_ACCESS) {
            c.ref_files.put(declaration.pos.fn, true);
        }
    }
    return c.ref_files.length() > 0;
}

func ref_body_file(ref c: Compiler, node: NodeID) -> String {
    if (!has_node(node)) { return ""; }
    let kind = node_tag(node);
    if (kind == NODE_BLOCK) {
        let block = get_block_node(ref c.arena, node);
        if (block.stmts is null || block.stmts.length() == 0) { return ""; }
        return ref_body_file(ref c, block.stmts[0]);
    }
    if (kind == NODE_VAR_DECL) { return get_var_decl_node(ref c.arena, node).pos.fn; }
    if (kind == NODE_VAR_ASSIGN) { return get_var_assign_node(ref c.arena, node).pos.fn; }
    if (kind == NODE_CALL) { return get_call_node(ref c.arena, node).pos.fn; }
    if (kind == NODE_RETURN) { return get_return_node(ref c.arena, node).pos.fn; }
    if (kind == NODE_IF) { return get_if_node(ref c.arena, node).pos.fn; }
    if (kind == NODE_WHILE) { return get_while_node(ref c.arena, node).pos.fn; }
    if (kind == NODE_FOR) { return get_for_node(ref c.arena, node).pos.fn; }
    return "";
}

func ref_error(ref state: RefCheck, pos: Position, operation: String) -> Void {
    if (state.active.length() == 0) { return; }
    throw_type_error(pos, "Cannot " + operation + " while element reference '" + state.active[0].name + "' is active.");
}

func ref_scalar(ref c: Compiler, type_id: Int) -> Bool {
    let type = get_repr_type(ref c, type_id);
    return is_numeric_type(type) || type == TYPE_BOOL || type == TYPE_CHAR || type == TYPE_STRING;
}

func ref_call_info(ref c: Compiler, callee: NodeID) -> FuncInfo {
    let name = "";
    if (node_tag(callee) == NODE_VAR_ACCESS) {
        name = get_var_access_node(ref c.arena, callee).name_tok.value;
        if (has_symbol(find_symbol(ref c, name))) { return FuncInfo(); }
    } else if (node_tag(callee) == NODE_FIELD_ACCESS) {
        name = format_ast_path(ref c, callee);
    } else {
        return FuncInfo();
    }
    let mapped = c.current_file_func_aliases.lookup(name);
    if (mapped is !null) { return c.func_table.lookup(mapped); }
    let info = c.func_table.lookup(c.current_package_prefix + name);
    if (has_func(info)) { return info; }
    return c.func_table.lookup(name);
}

func ref_check_call(ref c: Compiler, ref state: RefCheck, call: CallNode) -> Void {
// unknown calls may reach the same allocation through a field or a global alias
    if (state.collecting) {
        let i = 0;
        while (call.args is !null && i < call.args.length()) {
            let value = call.args[i].val;
            let target = value;
            if (node_tag(value) == NODE_REF) { target = get_ref_node(ref c.arena, value).node; }
            if (has_symbol(c.vector_base_map.lookup(get_repr_type(ref c, get_expr_type(ref c, target))))) {
                // a callee can publish this owner or return it under another name
                let owner = ref_owner(ref c, ref state, target);
                if (node_tag(value) == NODE_REF) { ref_join(ref state, owner, 0); }
                else { ref_publish(ref state, owner); }
            }
            i++;
        }
        return;
    }
    if (state.active.length() == 0) { return; }
    if (node_tag(call.callee) == NODE_FIELD_ACCESS) {
        let access = get_field_access_node(ref c.arena, call.callee);
        let target = get_repr_type(ref c, get_expr_type(ref c, access.obj));
        if (target == TYPE_STRING && access.field_name == "length") { return; }
        if (has_symbol(c.vector_base_map.lookup(target))) {
            if (access.field_name == "length") { return; }
            if (access.field_name == "append" || access.field_name == "drop") {
                ref_conflict(ref state, ref_owner(ref c, ref state, access.obj), call.pos, "call '" + access.field_name + "'");
                let element = c.vector_base_map.lookup(target).type;
                if (access.field_name == "drop" && !ref_plain_drop(ref c, element, 0)) {
                    ref_error(ref state, call.pos, "drop a value with unverified storage effects");
                }
                return;
            }
        }
    }

    if (node_tag(call.callee) == NODE_VAR_ACCESS && call.args is !null && call.args.length() == 1) {
        let name = get_var_access_node(ref c.arena, call.callee).name_tok.value;
        let type = get_builtin_cast_target(name);
        let arg = call.args[0];
        if (!has_symbol(find_symbol(ref c, name)) && ref_scalar(ref c, type) &&
            ref_scalar(ref c, get_expr_type(ref c, arg.val))) { return; }
    }

    let info = ref_call_info(ref c, call.callee);
    if (has_func(info) && (info.ann_flags & FLAG_ANN_INTRINSIC) != 0 && info.base_name == "print") {
        let safe = true;
        let i = 0;
        while (call.args is !null && i < call.args.length()) {
            let arg = call.args[i];
            if (arg.is_spread || !ref_scalar(ref c, get_expr_type(ref c, arg.val))) { safe = false; }
            i++;
        }
        if safe { return; }
    }
    ref_error(ref state, call.pos, "call a function with unverified storage effects");
}

func ref_check_write(ref c: Compiler, ref state: RefCheck, type_id: Int, owner: Int, pos: Position) -> Void {
    if (state.collecting || state.active.length() == 0) { return; }
    let type = get_repr_type(ref c, type_id);
    if (has_symbol(c.vector_base_map.lookup(type)) && ref_plain_drop(ref c, type, 0)) {
        ref_conflict(ref state, owner, pos, "replace managed storage");
        return;
    }
    // dropping a user object can enter deinit and reach the owner through an alias,
    // String cleanup has no user callback, replacing a string element is safe here
    if (type_id == 0 || type_id == TYPE_AUTO ||
        (get_repr_type(ref c, type_id) != TYPE_STRING && needs_drop(ref c, type_id))) {
        ref_error(ref state, pos, "replace managed storage");
    }
}

func ref_check_block(ref c: Compiler, ref state: RefCheck, body: NodeID) -> Bool {
    let saved_scope = c.symbol_table;
    let parent = c.scope_stack.length();
    c.scope_stack.append(saved_scope);
    c.symbol_table = Scope(table=Dict(), parent=parent, gc_vars=[], depth=saved_scope.depth + 1);
    let active = state.active.length();
    let block = get_block_node(ref c.arena, body);
    let terminated = false;
    let i = 0;
    while (block.stmts is !null && i < block.stmts.length() && !terminated) {
        terminated = ref_check_node(ref c, ref state, block.stmts[i]);
        i++;
    }
    // branch-local references must not restrict the next branch or the enclosing block
    while (state.active.length() > active) { state.active.drop(); }
    c.symbol_table = saved_scope;
    c.scope_stack.drop();
    return terminated;
}

func ref_check_node(ref c: Compiler, ref state: RefCheck, node: NodeID) -> Bool {
    if (!has_node(node)) { return false; }
    let kind = node_tag(node);
    if (kind == NODE_BLOCK) { return ref_check_block(ref c, ref state, node); }
    if (kind == NODE_VAR_DECL) {
        let declaration = get_var_decl_node(ref c.arena, node);
        ref_check_node(ref c, ref state, declaration.value);
        let type = resolve_type(ref c, declaration.type_node);
        let reference = false;
        if (has_node(declaration.value) && node_tag(declaration.value) == NODE_REF &&
            !is_pointer_type(ref c, type) && type != TYPE_ANYPTR) {
            let target = get_ref_node(ref c.arena, declaration.value).node;
            reference = true;
            if (type == TYPE_AUTO) { type = get_expr_type(ref c, target); }
            if (!state.collecting && node_tag(target) == NODE_INDEX_ACCESS) {
                let access = get_index_access_node(ref c.arena, target);
                let owner = get_repr_type(ref c, get_expr_type(ref c, access.target));
                if (has_symbol(c.vector_base_map.lookup(owner))) {
                    state.active.append(RefUse(name=declaration.name_tok.value, owner=ref_owner(ref c, ref state, access.target)));
                    c.ref_targets.put(UInt32(target), true);
                }
            }
        } else if (type == TYPE_AUTO && has_node(declaration.value)) {
            type = get_expr_type(ref c, declaration.value);
        }
        if (!reference && state.active.length() > 0 && needs_drop(ref c, type) && !ref_plain_drop(ref c, type, 0)) {
            ref_error(ref state, declaration.pos, "create a managed value with unverified drop effects");
        }
        let slot = "ref." + UInt32(node);
        if (state.collecting && has_symbol(c.vector_base_map.lookup(get_repr_type(ref c, type)))) {
            state.slots.put(slot, ref_owner(ref c, ref state, declaration.value));
        }
        c.symbol_table.table.put(declaration.name_tok.value, SymbolInfo(reg=slot, type=type, is_const=declaration.is_const, is_reference=reference));
        return false;
    }
    if (kind == NODE_VAR_ASSIGN) {
        let assignment = get_var_assign_node(ref c.arena, node);
        ref_check_node(ref c, ref state, assignment.value);
        let symbol = find_symbol(ref c, assignment.name_tok.value);
        let owner = 0;
        if (has_symbol(symbol) && symbol.reg is !null && state.slots.contains_key(symbol.reg)) {
            owner = state.slots.lookup(symbol.reg);
        }
        if (state.collecting && has_symbol(c.vector_base_map.lookup(get_repr_type(ref c, symbol.type)))) {
            ref_join(ref state, owner, ref_owner(ref c, ref state, assignment.value));
        }
        ref_check_write(ref c, ref state, symbol.type, owner, assignment.pos);
        return false;
    }
    if (kind == NODE_FIELD_ASSIGN) {
        let assignment = get_field_assign_node(ref c.arena, node);
        ref_check_node(ref c, ref state, assignment.obj);
        ref_check_node(ref c, ref state, assignment.value);
        let owner = c.struct_id_map.lookup(get_repr_type(ref c, get_expr_type(ref c, assignment.obj)));
        let type = find_field(owner, assignment.field_name).type;
        if (state.collecting && has_symbol(c.vector_base_map.lookup(get_repr_type(ref c, type)))) {
            ref_publish(ref state, ref_owner(ref c, ref state, assignment.value));
        }
        ref_check_write(ref c, ref state, type, 0, assignment.pos);
        return false;
    }
    if (kind == NODE_INDEX_ASSIGN) {
        let assignment = get_index_assign_node(ref c.arena, node);
        ref_check_node(ref c, ref state, assignment.target);
        ref_check_node(ref c, ref state, assignment.index_node);
        ref_check_node(ref c, ref state, assignment.value);
        let target = get_repr_type(ref c, get_expr_type(ref c, assignment.target));
        if (is_pointer_type(ref c, target)) { return false; }
        let array = c.array_info_map.lookup(target);
        let vector = c.vector_base_map.lookup(target);
        let element = 0;
        if (has_array_info(array)) { element = array.base_type; }
        if (has_symbol(vector)) { element = vector.type; }
        if (state.collecting && has_symbol(c.vector_base_map.lookup(get_repr_type(ref c, element)))) {
            ref_publish(ref state, ref_owner(ref c, ref state, assignment.value));
        }
        ref_check_write(ref c, ref state, element, 0, assignment.pos);
        return false;
    }
    if (kind == NODE_CALL) {
        let call = get_call_node(ref c.arena, node);
        ref_check_node(ref c, ref state, call.callee);
        let i = 0;
        while (call.args is !null && i < call.args.length()) {
            ref_check_node(ref c, ref state, call.args[i].val);
            i++;
        }
        ref_check_call(ref c, ref state, call);
        return false;
    }
    if (kind == NODE_IF) {
        let branch = get_if_node(ref c.arena, node);
        ref_check_node(ref c, ref state, branch.condition);
        let selected = fold_target_cond(ref c, branch.condition);
        if (node_tag(branch.condition) == NODE_BOOL) { selected = get_bool_node(ref c.arena, branch.condition).value; }
        if (selected == 1) { return ref_check_node(ref c, ref state, branch.body); }
        if (selected == 0) { return ref_check_node(ref c, ref state, branch.else_body); }
        let left = ref_check_node(ref c, ref state, branch.body);
        let right = ref_check_node(ref c, ref state, branch.else_body);
        return left && right;
    }
    if (kind == NODE_WHILE) {
        let loop = get_while_node(ref c.arena, node);
        ref_check_node(ref c, ref state, loop.condition);
        ref_check_node(ref c, ref state, loop.body);
        return false;
    }
    if (kind == NODE_FOR) {
        let loop = get_for_node(ref c.arena, node);
        let saved = c.symbol_table;
        let parent = c.scope_stack.length();
        c.scope_stack.append(saved);
        c.symbol_table = Scope(table=Dict(), parent=parent, gc_vars=[], depth=saved.depth + 1);
        let active = state.active.length();
        ref_check_node(ref c, ref state, loop.init);
        ref_check_node(ref c, ref state, loop.cond);
        ref_check_node(ref c, ref state, loop.body);
        ref_check_node(ref c, ref state, loop.step);
        while (state.active.length() > active) { state.active.drop(); }
        c.symbol_table = saved;
        c.scope_stack.drop();
        return false;
    }
    if (kind == NODE_CATCH) {
        let caught = get_catch_node(ref c.arena, node);
        let success = ref_check_node(ref c, ref state, caught.stmt);
        let failure = ref_check_node(ref c, ref state, caught.body);
        return success && failure;
    }
    if (kind == NODE_RETURN) {
        ref_check_node(ref c, ref state, get_return_node(ref c.arena, node).value);
        return true;
    }
    if (kind == NODE_THROW) {
        ref_check_node(ref c, ref state, get_throw_node(ref c.arena, node).value);
        return true;
    }
    if (kind == NODE_BREAK || kind == NODE_CONTINUE) { return true; }
    if (kind == NODE_BINOP || kind == NODE_IS || kind == NODE_IS_NOT) {
        let binary = get_binop_node(ref c.arena, node);
        ref_check_node(ref c, ref state, binary.left);
        ref_check_node(ref c, ref state, binary.right);
        if (kind == NODE_BINOP && state.active.length() > 0 &&
            (!ref_scalar(ref c, get_expr_type(ref c, binary.left)) || !ref_scalar(ref c, get_expr_type(ref c, binary.right)))) {
            ref_error(ref state, binary.pos, "use an operator with unverified storage effects");
        }
        return false;
    }
    if (kind == NODE_UNARYOP || kind == NODE_POSTFIX) {
        let operand = NO_NODE;
        let pos = no_position();
        if (kind == NODE_UNARYOP) {
            let unary = get_unary_node(ref c.arena, node);
            operand = unary.node;
            pos = unary.pos;
        } else {
            let postfix = get_postfix_node(ref c.arena, node);
            operand = postfix.node;
            pos = postfix.pos;
        }
        ref_check_node(ref c, ref state, operand);
        if (state.active.length() > 0 && !ref_scalar(ref c, get_expr_type(ref c, operand))) {
            ref_error(ref state, pos, "use an operator with unverified storage effects");
        }
        return false;
    }
    if (kind == NODE_FIELD_ACCESS) { return ref_check_node(ref c, ref state, get_field_access_node(ref c.arena, node).obj); }
    if (kind == NODE_REF) { return ref_check_node(ref c, ref state, get_ref_node(ref c.arena, node).node); }
    if (kind == NODE_DEREF) { return ref_check_node(ref c, ref state, get_deref_node(ref c.arena, node).node); }
    if (kind == NODE_TRY_UNWRAP) { return ref_check_node(ref c, ref state, get_try_unwrap_node(ref c.arena, node).expr); }
    if (kind == NODE_PTR_ASSIGN) {
        let assignment = get_ptr_assign_node(ref c.arena, node);
        ref_check_node(ref c, ref state, assignment.pointer);
        ref_check_node(ref c, ref state, assignment.value);
        return false;
    }
    if (kind == NODE_INDEX_ACCESS) {
        let access = get_index_access_node(ref c.arena, node);
        ref_check_node(ref c, ref state, access.target);
        ref_check_node(ref c, ref state, access.index_node);
        return false;
    }
    if (kind == NODE_SLICE_ACCESS) {
        let access = get_slice_access_node(ref c.arena, node);
        ref_check_node(ref c, ref state, access.target);
        ref_check_node(ref c, ref state, access.start_idx);
        ref_check_node(ref c, ref state, access.end_idx);
        return false;
    }
    if (kind == NODE_VECTOR_LIT) {
        let literal = get_vector_lit_node(ref c.arena, node);
        let i = 0;
        while (literal.elements is !null && i < literal.elements.length()) {
            ref_check_node(ref c, ref state, literal.elements[i].val);
            if (state.collecting && has_symbol(c.vector_base_map.lookup(get_repr_type(ref c, get_expr_type(ref c, literal.elements[i].val))))) {
                ref_publish(ref state, ref_owner(ref c, ref state, literal.elements[i].val));
            }
            i++;
        }
        return false;
    }
    if (kind == NODE_MAP_LIT) {
        let literal = get_map_lit_node(ref c.arena, node);
        let i = 0;
        while (literal.pairs is !null && i < literal.pairs.length()) {
            let pair = literal.pairs[i];
            ref_check_node(ref c, ref state, pair.key);
            ref_check_node(ref c, ref state, pair.value);
            if (state.collecting && has_symbol(c.vector_base_map.lookup(get_repr_type(ref c, get_expr_type(ref c, pair.value))))) {
                ref_publish(ref state, ref_owner(ref c, ref state, pair.value));
            }
            i++;
        }
        return false;
    }
    if (kind == NODE_FUNC_DEF) {
        if (state.collecting) {
            let i = 0;
            while (i < state.parents.length()) {
                ref_join(ref state, i, 0);
                i++;
            }
        } else if (state.active.length() > 0) {
            ref_error(ref state, get_func_def_node(ref c.arena, node).pos, "create a closure with unverified capture effects");
        }
    }
    return false;
}

func check_body_refs(ref c: Compiler, body: NodeID, inputs: Dict(String, SymbolInfo)) -> Bool {
// this walk has its own lexical tables, lowering must retain its real binding addresses
    if (!has_index_refs(ref c)) { return true; }
    let file = ref_body_file(ref c, body);
    if (file.length() > 0 && !c.ref_files.contains_key(file)) { return true; }

    let errors = GLOBAL_ERROR_COUNT;
    let scope = c.symbol_table;
    let stack = c.scope_stack;
    let hoist = c.hoist_scope;
    let hoist_stack = c.hoist_scope_stack;
    c.symbol_table = Scope(table=inputs, parent=-1, gc_vars=[], depth=0);
    c.scope_stack = [];
    c.hoist_scope = Scope();
    c.hoist_scope_stack = [];
    let state = RefCheck(active=[], parents=[0], escaped=[true], slots=Dict(), allocations=Dict(), collecting=true);
    ref_check_node(ref c, ref state, body);
    state.collecting = false;
    ref_check_node(ref c, ref state, body);
    c.symbol_table = scope;
    c.scope_stack = stack;
    c.hoist_scope = hoist;
    c.hoist_scope_stack = hoist_stack;
    return GLOBAL_ERROR_COUNT == errors;
}
