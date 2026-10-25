// src/compiler/references.wl
import * from "../frontend/ast.wl"
import * from "../frontend/arena.wl"
import TOK_AND, TOK_OR from "../frontend/tokens.wl"
import * from "../frontend/diagnostics.wl"
import * from "context.wl"
import * from "target_eval.wl"
import * from "narrowing.wl"
import bind_native_args, bind_callable_args from "validation.wl"


struct RefUse(name: String, owner: Int, slot: String, element: Int)
struct RefCheck(
    active: Vector(RefUse), parents: Vector(Int), escaped: Vector(Bool),
    slots: Dict(String, Int), slot_names: Vector(String), slot_refs: Dict(String, String),
    allocations: Dict(String, Int), collecting: Bool, loop_depth: Int,
    frame: Int, next_frame: Int, calls: Vector(String), budget: Int,
    functions: Dict(String, FuncInfo)
)

func ref_storage(ref c: Compiler, type_id: Int) -> Bool {
    type_id = get_repr_type(ref c, type_id);
    let array = c.array_info_map.lookup(type_id);
    return (c.vector_base_map.lookup(type_id) is !null) || ((array is !null) && array.size < 0);
}

func ref_element(ref c: Compiler, type_id: Int) -> Int {
    type_id = get_repr_type(ref c, type_id);
    let array = c.array_info_map.lookup(type_id);
    if ((array is !null)) { return array.base_type; }
    let vector = c.vector_base_map.lookup(type_id);
    if ((vector is !null)) { return vector.type; }
    return 0;
}

func ref_slot(ref state: RefCheck, slot: String) -> String {
    let target = state.slot_refs.lookup(slot);
    if (target is !null) { return target; }
    return slot;
}

func ref_set_slot(ref state: RefCheck, slot: String, owner: Int) -> Void {
    slot = ref_slot(ref state, slot);
    if (!state.slots.contains_key(slot)) { state.slot_names.append(slot); }
    state.slots.put(slot, owner);
}

func ref_snapshot(ref state: RefCheck) -> Dict(String, Int) {
// copying the map itself would share its storage, branches need separate binding state
    let copy: Dict(String, Int) = Dict();
    let i = 0;
    while (i < state.slot_names.length()) {
        let key = state.slot_names[i];
        let owner = state.slots.lookup(key);
        if (owner is !null) { copy.put(key, owner); }
        i++;
    }
    return copy;
}

func ref_merge(ref state: RefCheck, left: Dict(String, Int), left_ends: Bool, right_ends: Bool) -> Void {
    let i = 0;
    while (i < state.slot_names.length()) {
        let key = state.slot_names[i];
        let owner = left.lookup(key);
        let other = state.slots.lookup(key);
        if (owner is !null && other is !null) {
            if (!left_ends && !right_ends) { ref_join(ref state, owner, other); }
            if (!left_ends) { state.slots.put(key, owner); }
        }
        i++;
    }
}

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
// joins describe control-flow alternatives, ordinary reassignment replaces a binding's owner
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
    let key = state.frame + "." + UInt32(node);
    let existing = state.allocations.lookup(key);
    if (existing is !null) { return existing; }
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
    if (kind == NODE_SLICE_ACCESS) { return ref_allocation(ref state, node); }
    if (kind == NODE_VAR_ACCESS) {
        let name = get_var_access_node(ref c.arena, node).name_tok.value;
        let symbol = find_symbol(ref c, name);
        if ((symbol is !null) && state.slots.contains_key(ref_slot(ref state, symbol.reg))) {
            let owner = state.slots.lookup(ref_slot(ref state, symbol.reg));
            if (owner is !null) { return ref_group(ref state, owner); }
        }
    }
    if (kind == NODE_REF) {
        let target = get_ref_node(ref c.arena, node).node;
        if (node_tag(target) == NODE_SLICE_ACCESS) {
            return ref_owner(ref c, ref state, get_slice_access_node(ref c.arena, target).target);
        }
        return ref_owner(ref c, ref state, target);
    }
    return 0;
}

func ref_conflict(ref state: RefCheck, owner: Int, pos: Position, operation: String, element: Int = 0) -> Void {
    owner = ref_group(ref state, owner);
    let i = 0;
    while (i < state.active.length()) {
        let use = state.active[i];
        let active_owner = ref_group(ref state, use.owner);
        if ((owner == 0 || active_owner == 0) && element != 0 && use.element != 0 && element != use.element) {
            i++;
            continue;
        }
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
    let found_union: Optional(UnionInfo) = get_union_type(ref c, type_id);
    if (found_union is !null) {
        let union: UnionInfo = found_union;
        // cleanup can visit any stored arm, a harmless current value is not enough
        let i = 0;
        while (i < union.members.length()) {
            if (!ref_plain_drop(ref c, union.members[i], depth + 1)) { return false; }
            i++;
        }
        return true;
    }
    let vector: Optional(SymbolInfo) = c.vector_base_map.lookup(type_id);
    if ((vector is !null)) { return ref_plain_drop(ref c, vector.type, depth + 1); }
    let array: Optional(ArrayInfo) = c.array_info_map.lookup(type_id);
    if ((array is !null)) { return ref_plain_drop(ref c, array.base_type, depth + 1); }
    let record: Optional(StructInfo) = c.struct_id_map.lookup(type_id);
    if (!(record is !null) || record.is_class || record.is_interface) { return false; }
    let meta_record: StructInfo = record;
    let i = 0;
    while (i < meta_record.fields.length()) {
        let field: FieldInfo = meta_record.fields[i];
        if (!ref_plain_drop(ref c, field.type, depth + 1)) { return false; }
        i++;
    }
    return true;
}

func has_index_refs(ref c: Compiler) -> Bool {
// skip the extra body walk in files which only use stable slots or explicit pointers
    if (!c.ref_index_ready) {
        c.ref_index_ready = true;
        c.ref_files = Dict();
        c.ref_targets = Dict();
        c.ref_scan = 0;
        c.ref_call_scan = 0;
        c.ref_callees = Dict();
        let i = 0;
        while (i < c.arena.func_def_nodes.length()) {
            let function = c.arena.func_def_nodes[i];
            ref_register_params(ref c, function.name_tok.value, function.params);
            i++;
        }
        i = 0;
        while (i < c.arena.method_def_nodes.length()) {
            let member = c.arena.method_def_nodes[i];
            ref_register_params(ref c, member.name_tok.value, member.params);
            i++;
        }
        i = 0;
        while (i < c.arena.extern_func_nodes.length()) {
            let function = c.arena.extern_func_nodes[i];
            c.ref_callees.put(function.name_tok.value, true);
            i++;
        }
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
    while (c.ref_call_scan < c.arena.call_nodes.length()) {
        let call = c.arena.call_nodes[c.ref_call_scan];
        c.ref_call_scan++;
        let name = "";
        if (node_tag(call.callee) == NODE_VAR_ACCESS) { name = get_var_access_node(ref c.arena, call.callee).name_tok.value; }
        if (node_tag(call.callee) == NODE_FIELD_ACCESS) { name = get_field_access_node(ref c.arena, call.callee).field_name; }
        let i = 0;
        while (i < call.args.length()) {
            let arg = call.args[i];
            if (node_tag(arg.val) == NODE_REF && node_tag(get_ref_node(ref c.arena, arg.val).node) == NODE_INDEX_ACCESS) {
                let key = name + "." + i;
                if (arg.name.length() != 0) { key = name + "." + arg.name; }
                if (!c.ref_callees.contains_key(name) || c.ref_callees.contains_key(key)) {
                    c.ref_files.put(call.pos.fn, true);
                }
            }
            i++;
        }
    }
    return c.ref_files.length() > 0;
}

func ref_register_params(ref c: Compiler, name: String, params: Vector(ParamNode)) -> Void {
// this gate only avoids body walks, the resolved call signature decides whether an argument is a reference
    c.ref_callees.put(name, true);
    let i = 0;
    while (i < params.length()) {
        let param = params[i];
        if (param.pass_mode == PARAM_REF) {
            c.ref_callees.put(name + "." + i, true);
            c.ref_callees.put(name + "." + param.name_tok.value, true);
        }
        i++;
    }
}

func ref_owner_slot(ref c: Compiler, ref state: RefCheck, target: NodeID) -> String {
    if (node_tag(target) != NODE_VAR_ACCESS) { return ""; }
    let symbol = find_symbol(ref c, get_var_access_node(ref c.arena, target).name_tok.value);
    if (!(symbol is !null)) { return ""; }
    return ref_slot(ref state, symbol.reg);
}

func ref_stable_owner(ref c: Compiler, node: NodeID) -> Bool {
    if (node_tag(node) == NODE_VAR_ACCESS) {
        return (find_symbol(ref c, get_var_access_node(ref c.arena, node).name_tok.value) is !null);
    }
    if (node_tag(node) == NODE_FIELD_ACCESS) {
        let access = get_field_access_node(ref c.arena, node);
        let owner = c.struct_id_map.lookup(get_repr_type(ref c, get_expr_type(ref c, access.obj)));
        return (owner is !null) && !owner.is_class && ref_stable_owner(ref c, access.obj);
    }
    return false;
}

func ref_body_file(ref c: Compiler, node: NodeID) -> String {
    if (!has_node(node)) { return ""; }
    let kind = node_tag(node);
    if (kind == NODE_BLOCK) {
        let block = get_block_node(ref c.arena, node);
        if (block.stmts.length() == 0) { return ""; }
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
    let record = c.struct_id_map.lookup(type);
    return is_numeric_type(type) || type == TYPE_BOOL || type == TYPE_CHAR || type == TYPE_STRING ||
           ((record is !null) && record.is_enum);
}

func ref_scalar_expr(ref c: Compiler, node: NodeID) -> Bool {
    if (ref_scalar(ref c, get_expr_type(ref c, node))) { return true; }
    if (node_tag(node) == NODE_CALL) {
        let info = ref_resolve_call(ref c, get_call_node(ref c.arena, node));
        return (info is !null) && ref_scalar(ref c, info.ret_type);
    }
    if (node_tag(node) != NODE_FIELD_ACCESS) { return false; }
    let access = get_field_access_node(ref c.arena, node);
    let name = format_ast_path(ref c, access.obj);
    let mapped = c.current_file_type_aliases.lookup(name);
    if (mapped is !null) { name = mapped; }
    let record = c.struct_table.lookup(name);
    if (!(record is !null)) { record = c.struct_table.lookup(c.current_package_prefix + name); }
    return (record is !null) && record.is_enum;
}

func ref_call_info(ref c: Compiler, callee: NodeID) -> Optional(FuncInfo) {
    let name = "";
    if (node_tag(callee) == NODE_VAR_ACCESS) {
        name = get_var_access_node(ref c.arena, callee).name_tok.value;
        if ((find_symbol(ref c, name) is !null)) { return null; }
    } else if (node_tag(callee) == NODE_FIELD_ACCESS) {
        name = format_ast_path(ref c, callee);
        let root = callee;
        while (node_tag(root) == NODE_FIELD_ACCESS) { root = get_field_access_node(ref c.arena, root).obj; }
        if (node_tag(root) == NODE_VAR_ACCESS) {
            let local = get_var_access_node(ref c.arena, root).name_tok.value;
            if ((find_symbol(ref c, local) is !null)) { return null; }
            let prefix = c.current_file_visible_prefixes.lookup(local);
            if (prefix is !null) { name = prefix + name.slice(local.length() + 1, name.length()); }
        }
    } else {
        return null;
    }
    let mapped = c.current_file_func_aliases.lookup(name);
    if (mapped is !null) { return c.func_table.lookup(mapped); }
    let info = c.func_table.lookup(c.current_package_prefix + name);
    if ((info is !null)) { return info; }
    return c.func_table.lookup(name);
}

func ref_resolve_call(ref c: Compiler, call: CallNode) -> Optional(FuncInfo) {
    let info = ref_call_info(ref c, call.callee);
    if ((info is !null)) { return info; }
    if (node_tag(call.callee) == NODE_FIELD_ACCESS) {
        let access = get_field_access_node(ref c.arena, call.callee);
        let owner = c.struct_id_map.lookup(get_repr_type(ref c, get_expr_type(ref c, access.obj)));
        if ((owner is !null) && owner.is_class) {
            let record: StructInfo = owner;
            let template = c.generic_methods.lookup(record.name + "_" + access.field_name);
            if ((template is !null)) {
                let types = resolve_generic_method_args(ref c, template, call.type_args, call.args, call.pos);
                if (types is null) { return null; }
                return register_generic_method(ref c, template, record, types, call.pos);
            }
            info = c.func_table.lookup(record.name + "_" + access.field_name);
            if ((info is !null)) { return info; }
            let i = 0;
            while (i < record.vtable.length()) {
                let member: FuncInfo = record.vtable[i];
                if (member.base_name == access.field_name) { return member; }
                i++;
            }
        }
    }
    if (node_tag(call.callee) == NODE_VAR_ACCESS &&
        (find_symbol(ref c, get_var_access_node(ref c.arena, call.callee).name_tok.value) is !null)) {
        return null;
    }
    let name = generic_symbol_name(ref c, call.callee, true);
    let template = c.generic_funcs.lookup(name);
    if (!(template is !null)) { return null; }
    let args = resolve_generic_args(ref c, template, call.type_args, call.args, call.pos);
    if (args is null) { return null; }
    return register_generic_func(ref c, template, args, call.pos);
}

func ref_known_call(ref c: Compiler, ref state: RefCheck, call: CallNode) -> Optional(FuncInfo) {
    if (node_tag(call.callee) == NODE_VAR_ACCESS) {
        let symbol = find_symbol(ref c, get_var_access_node(ref c.arena, call.callee).name_tok.value);
        if ((symbol is !null)) { return state.functions.lookup(symbol.reg); }
    }
    return ref_resolve_call(ref c, call);
}

func ref_method_call(ref c: Compiler, call: CallNode, info: FuncInfo, receiver_type: Int = 0) -> Bool {
    if (node_tag(call.callee) != NODE_FIELD_ACCESS ||
        info.arg_names.length() == 0 || info.arg_names[0] != "self") { return false; }
    let access = get_field_access_node(ref c.arena, call.callee);
    if (receiver_type == 0) { receiver_type = get_expr_type(ref c, access.obj); }
    let actual = c.struct_id_map.lookup(get_repr_type(ref c, receiver_type));
    return (actual is !null) && actual.is_class;
}

func ref_constructor(ref c: Compiler, callee: NodeID) -> Optional(StructInfo) {
// a namespace-qualified type name needs the module prefix, a local callable can shadow it
    let root = callee;
    while (node_tag(root) == NODE_FIELD_ACCESS) { root = get_field_access_node(ref c.arena, root).obj; }
    if (node_tag(root) != NODE_VAR_ACCESS ||
        (find_symbol(ref c, get_var_access_node(ref c.arena, root).name_tok.value) is !null)) {
        return null;
    }
    let name = generic_symbol_name(ref c, callee, false);
    let record = c.struct_table.lookup(name);
    if (!(record is !null)) { record = c.struct_table.lookup(c.current_package_prefix + name); }
    return record;
}

func ref_call_body(ref c: Compiler, ref state: RefCheck, call: CallNode, info: FuncInfo, receiver_type: Int = 0) -> Bool {
// analyze a direct body with the caller's allocation identities, imports belong to the callee
    if (!has_node(info.ref_body) || info.is_varargs || info.variadic_param > 0) { return false; }
    if (state.calls.length() >= 16 || state.budget <= 0) { return false; }
    let i = 0;
    while (i < state.calls.length()) {
        // recursive calls require a fixed-point effect summary, a partial walk cannot prove them safe
        if (state.calls[i] == info.name) { return false; }
        i++;
    }

    let owners: Vector(Int) = [];
    let sources: Vector(String) = [];
    let receiver = NO_NODE;
    if (ref_method_call(ref c, call, info, receiver_type)) {
        receiver = get_field_access_node(ref c.arena, call.callee).obj;
    }
    i = 0;
    while (i < info.arg_names.length()) {
        let argument = NO_NODE;
        let arg_index = i;
        if (has_node(receiver)) {
            if (i == 0) { argument = receiver; }
            arg_index--;
        }
        let index = 0;
        while (index < call.args.length()) {
            let arg = call.args[index];
            if ((arg.name.length() == 0 && index == arg_index) || arg.name == info.arg_names[i]) { argument = arg.val; }
            index++;
        }
        if (!has_node(argument) && arg_index >= 0 && arg_index < info.default_args.length()) {
            argument = info.default_args[arg_index];
        }
        let owner = ref_owner(ref c, ref state, argument);
        let source = "";
        if (node_tag(argument) == NODE_REF) {
            let target = get_ref_node(ref c.arena, argument).node;
            if (node_tag(target) == NODE_VAR_ACCESS) {
                let symbol = find_symbol(ref c, get_var_access_node(ref c.arena, target).name_tok.value);
                if ((symbol is !null)) { source = ref_slot(ref state, symbol.reg); }
            }
        }
        owners.append(owner);
        sources.append(source);
        i++;
    }

    let scope = c.symbol_table;
    let stack = c.scope_stack;
    let hoist = c.hoist_scope;
    let hoist_stack = c.hoist_scope_stack;
    let facts = c.flow_types;
    let exposed = c.flow_exposed;
    let bindings = c.generic_bindings;
    let saved_context = info.ref_context;
    if (saved_context is null) { return false; }
    let body_context: GenericTemplate = saved_context;
    let saved_bindings = info.ref_bindings;
    let callee_bindings: Dict(String, SymbolInfo) = Dict();
    if (saved_bindings is !null) { callee_bindings = saved_bindings; }
    let context = use_generic_context(ref c, body_context, callee_bindings);
    let frame = state.frame;
    let loop_depth = state.loop_depth;
    state.next_frame++;
    state.frame = state.next_frame;
    state.loop_depth = 0;
    state.calls.append(info.name);
    c.symbol_table = Scope(table=Dict(), parent=-1, gc_vars=[], depth=0);
    c.scope_stack = [];
    c.hoist_scope = Scope(table=null, parent=0, gc_vars=[], depth=0);
    c.hoist_scope_stack = [];
    i = 0;
    while (i < info.arg_names.length()) {
        let param: TypeListNode = info.arg_types[i];
        let slot = "arg." + state.frame + "." + i;
        scope_put(c.symbol_table, info.arg_names[i], SymbolInfo(reg=slot, type=param.type, is_reference=param.pass_mode == PARAM_REF, origin_type=0, is_const=false, is_const_access=false, is_ref_param=false, func_arg_types=[], arg_names=[], variadic_param=0));
        if (ref_storage(ref c, param.type)) {
            if (param.pass_mode == PARAM_REF && sources[i].length() != 0) { state.slot_refs.put(slot, sources[i]); }
            ref_set_slot(ref state, slot, owners[i]);
        }
        i++;
    }

    let active = state.active;
    let before = ref_snapshot(ref state);
    state.active = [];
    state.collecting = true;
    c.flow_types = [];
    c.flow_exposed = [];
    ref_check_node(ref c, ref state, info.ref_body);
    state.slots = before;
    state.collecting = false;
    state.active = active;
    c.flow_types = [];
    c.flow_exposed = [];
    ref_check_node(ref c, ref state, info.ref_body);

    c.flow_types = facts;
    c.flow_exposed = exposed;
    c.symbol_table = scope;
    c.scope_stack = stack;
    c.hoist_scope = hoist;
    c.hoist_scope_stack = hoist_stack;
    restore_generic_context(ref c, context, bindings);
    state.calls.drop();
    state.frame = frame;
    state.loop_depth = loop_depth;
    return true;
}

func ref_check_call(ref c: Compiler, ref state: RefCheck, call: CallNode, info: FuncInfo, receiver_type: Int) -> Void {
// unknown calls may reach the same allocation through a field or a global alias
    if (state.collecting) {
        let i = 0;
        while (i < call.args.length()) {
            let value = call.args[i].val;
            let target = value;
            if (node_tag(value) == NODE_REF) { target = get_ref_node(ref c.arena, value).node; }
            if (ref_storage(ref c, get_expr_type(ref c, target))) {
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
        let target = receiver_type;
        if (target == 0) { target = get_expr_type(ref c, access.obj); }
        target = get_repr_type(ref c, target);
        if (target == TYPE_STRING && access.field_name == "length") { return; }
        let vector = c.vector_base_map.lookup(target);
        if (vector is !null) {
            if (access.field_name == "length") { return; }
            if (access.field_name == "append" || access.field_name == "drop") {
                ref_conflict(ref state, ref_owner(ref c, ref state, access.obj), call.pos, "call '" + access.field_name + "'", ref_element(ref c, target));
                let element = vector.type;
                if (access.field_name == "drop" && !ref_drop_effects(ref c, ref state, element, call.pos, 0)) {
                    ref_error(ref state, call.pos, "drop a value with unverified storage effects");
                }
                return;
            }
        }
    }

    if (node_tag(call.callee) == NODE_VAR_ACCESS && call.args.length() == 1) {
        let name = get_var_access_node(ref c.arena, call.callee).name_tok.value;
        let type = get_cast_target(ref c, name);
        let arg = call.args[0];
        if (!(find_symbol(ref c, name) is !null) && ref_scalar(ref c, type) &&
            ref_scalar_expr(ref c, arg.val)) { return; }
    }

    if (!has_func(info)) {
        let known = ref_known_call(ref c, ref state, call);
        if (known is !null) { info = known; }
    }
    if (!has_func(info)) {
        // record construction evaluates its field arguments, it has no hidden method body
        let record = ref_constructor(ref c, call.callee);
        if ((record is !null) && !record.is_class && !record.is_interface && !record.is_enum) { return; }
    }
    if (has_func(info) && (info.ann_flags & FLAG_ANN_INTRINSIC) != 0 && info.base_name == "print") {
        let safe = true;
        let i = 0;
        while (i < call.args.length()) {
            let arg = call.args[i];
            if (arg.is_spread || !ref_scalar_expr(ref c, arg.val)) { safe = false; }
            i++;
        }
        if safe { return; }
    }
    if (has_func(info) && info.compiler_link_name.length() != 0) {
        let link = info.compiler_link_name;
        let scalar = true;
        let i = 0;
        if (ref_method_call(ref c, call, info, receiver_type)) { i = 1; }
        while (i < info.arg_types.length()) {
            let param: TypeListNode = info.arg_types[i];
            if (!ref_scalar(ref c, param.type)) { scalar = false; }
            i++;
        }
        if (link == "zero_value" || (scalar && (link == "hash_value" || link == "values_equal"))) { return; }
        ref_error(ref state, call.pos, "call a function with unverified storage effects");
        return;
    }
    if (has_func(info) && ref_call_body(ref c, ref state, call, info, receiver_type)) {
        ref_check_overrides(ref c, ref state, call, info, receiver_type);
        return;
    }
    ref_error(ref state, call.pos, "call a function with unverified storage effects");
}

func ref_check_overrides(ref c: Compiler, ref state: RefCheck, call: CallNode, info: FuncInfo, receiver_type: Int) -> Void {
// a method reached through a base class may execute a subclass body
    if (!ref_method_call(ref c, call, info, receiver_type)) { return; }
    let param: TypeListNode = info.arg_types[0];
    let owner = c.struct_id_map.lookup(param.type);
    if (!(owner is !null) || !owner.is_class) { return; }
    let record: StructInfo = owner;
    let i = 0;
    while (i < c.struct_id_map.capacity) {
        if (c.struct_id_map.hashes[i] >= 2) {
            let candidate = c.struct_id_map.values[i];
            if (candidate.is_class && candidate.parent_id != 0) {
                let parent = candidate.parent_id;
                let depth = 0;
                while (parent != 0 && parent != record.type_id && depth < 64) {
                    let ancestor = c.struct_id_map.lookup(parent);
                    if (ancestor is null) { break; }
                    parent = ancestor.parent_id;
                    depth++;
                }
                if (parent == record.type_id) {
                    let index = 0;
                    while (index < candidate.vtable.length()) {
                        let member: FuncInfo = candidate.vtable[index];
                        if (member.base_name == info.base_name && member.name != info.name &&
                            !ref_call_body(ref c, ref state, call, member, receiver_type)) {
                            ref_error(ref state, call.pos, "call a function with unverified storage effects");
                        }
                        index++;
                    }
                }
            }
        }
        i++;
    }
}

func ref_check_write(ref c: Compiler, ref state: RefCheck, type_id: Int, owner: Int, pos: Position, slot: String = "") -> Void {
    if (state.collecting || state.active.length() == 0) { return; }
    let type = get_repr_type(ref c, type_id);
    if (ref_storage(ref c, type)) {
        if (slot.length() > 0) {
            let retained = true;
            let kept = false;
            let i = 0;
            while (i < state.active.length()) {
                let use = state.active[i];
                let root = ref_group(ref state, owner);
                let active = ref_group(ref state, use.owner);
                let possible = root == active || (root == 0 && state.escaped[active]) || (active == 0 && state.escaped[root]);
                let saved = state.slots.lookup(use.slot);
                if (root != 0 && root == active && slot != use.slot && use.slot.length() > 0 &&
                    saved is !null && ref_group(ref state, saved) == active) { kept = true; }
                if (possible && (slot == use.slot || use.slot.length() == 0 || saved is null ||
                     ref_group(ref state, saved) != ref_group(ref state, use.owner))) {
                    retained = false;
                }
                i++;
            }
            if (retained && kept) { return; }
        }
        ref_conflict(ref state, owner, pos, "replace managed storage", ref_element(ref c, type));
        if (!ref_drop_effects(ref c, ref state, type, pos, 0)) { ref_error(ref state, pos, "replace managed storage"); }
        return;
    }
    // dropping a user object can enter deinit and reach the owner through an alias,
    // String cleanup has no user callback, replacing a string element is safe here
    if (type_id == 0 || type_id == TYPE_AUTO || !ref_drop_effects(ref c, ref state, type_id, pos, 0)) {
        ref_error(ref state, pos, "replace managed storage");
    } else if (needs_drop(ref c, type_id) && type != TYPE_STRING) {
        ref_check_fields(ref c, ref state, type, pos, 0);
    }
}

func ref_drop_effects(ref c: Compiler, ref state: RefCheck, type_id: Int, pos: Position, depth: Int) -> Bool {
// a class destructor is ordinary user code, inspect its body before permitting cleanup
    if (ref_plain_drop(ref c, type_id, 0)) { return true; }
    if (depth > 16) { return false; }
    type_id = get_repr_type(ref c, type_id);
    let found_union: Optional(UnionInfo) = get_union_type(ref c, type_id);
    if (found_union is !null) {
        let union: UnionInfo = found_union;
        let i = 0;
        while (i < union.members.length()) {
            if (!ref_drop_effects(ref c, ref state, union.members[i], pos, depth + 1)) { return false; }
            i++;
        }
        return true;
    }
    if (ref_storage(ref c, type_id)) { return ref_drop_effects(ref c, ref state, ref_element(ref c, type_id), pos, depth + 1); }
    let record = c.struct_id_map.lookup(type_id);
    if (!(record is !null) || record.is_interface) { return false; }
    let info: StructInfo = record;
    if (!ref_drop_record(ref c, ref state, info, pos, depth)) { return false; }
    if (!info.is_class) { return true; }
    let i = 0;
    while (i < c.struct_id_map.capacity) {
        if (c.struct_id_map.hashes[i] >= 2) {
            let candidate = c.struct_id_map.values[i];
            if (candidate.is_class && candidate.parent_id != 0) {
                let parent = candidate.parent_id;
                let count = 0;
                while (parent != 0 && parent != info.type_id && count < 64) {
                    let ancestor = c.struct_id_map.lookup(parent);
                    if (ancestor is null) { return false; }
                    parent = ancestor.parent_id;
                    count++;
                }
                if (parent == info.type_id && !ref_drop_record(ref c, ref state, candidate, pos, depth)) { return false; }
            }
        }
        i++;
    }
    return true;
}

func ref_drop_record(ref c: Compiler, ref state: RefCheck, record: StructInfo, pos: Position, depth: Int) -> Bool {
    let deinit = c.func_table.lookup(record.name + "_$deinit");
    if ((deinit is !null)) {
        let call = CallNode(callee=NO_NODE, args=[], pos=pos, type=0, type_args=[], preserve_fallible=false);
        if (!ref_call_body(ref c, ref state, call, deinit)) { return false; }
    }
    let i = 0;
    while (i < record.fields.length()) {
        let field: FieldInfo = record.fields[i];
        if (!ref_drop_effects(ref c, ref state, field.type, pos, depth + 1)) { return false; }
        if (ref_storage(ref c, field.type)) {
            ref_conflict(ref state, 0, pos, "replace managed storage", ref_element(ref c, field.type));
        }
        i++;
    }
    return true;
}

func ref_check_fields(ref c: Compiler, ref state: RefCheck, type_id: Int, pos: Position, depth: Int) -> Void {
// replacing a value record can release an owner stored in one of its fields
    if (depth > 16) {
        ref_error(ref state, pos, "replace managed storage");
        return;
    }
    type_id = get_repr_type(ref c, type_id);
    let found_union: Optional(UnionInfo) = get_union_type(ref c, type_id);
    if (found_union is !null) {
        let union: UnionInfo = found_union;
        let i = 0;
        while (i < union.members.length()) {
            if (needs_drop(ref c, union.members[i])) {
                ref_check_fields(ref c, ref state, union.members[i], pos, depth + 1);
            }
            i++;
        }
        return;
    }
    if (ref_storage(ref c, type_id)) {
        ref_conflict(ref state, 0, pos, "replace managed storage", ref_element(ref c, type_id));
        return;
    }
    let record = c.struct_id_map.lookup(get_repr_type(ref c, type_id));
    if (!(record is !null) || record.is_enum) { return; }
    let info: StructInfo = record;
    let i = 0;
    while (i < info.fields.length()) {
        let field: FieldInfo = info.fields[i];
        if (needs_drop(ref c, field.type)) { ref_check_fields(ref c, ref state, field.type, pos, depth + 1); }
        i++;
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
    while (i < block.stmts.length() && !terminated) {
        terminated = ref_check_node(ref c, ref state, block.stmts[i]);
        i++;
    }
    // branch-local references must not restrict the next branch or the enclosing block
    while (state.active.length() > active) { state.active.drop(); }
    // a local guard uses its spelling, discard it before an outer binding becomes visible
    i = 0;
    while (i < block.stmts.length()) {
        if (node_tag(block.stmts[i]) == NODE_VAR_DECL) {
            flow_forget(ref c, get_var_decl_node(ref c.arena, block.stmts[i]).name_tok.value, false);
        }
        i++;
    }
    c.symbol_table = saved_scope;
    c.scope_stack.drop();
    return terminated;
}

func ref_check_node(ref c: Compiler, ref state: RefCheck, node: NodeID) -> Bool {
// the effect walk uses the same guard lifetime as lowering, callees have separate facts
    if (!has_node(node)) { return false; }
    let kind = node_tag(node);
    if (kind == NODE_WHILE || kind == NODE_FOR) { c.flow_types = []; }
    let result = ref_check_raw_node(ref c, ref state, node);
    if (kind == NODE_CALL) { flow_forget(ref c, "", true); }
    if (kind == NODE_REF) { flow_expose(ref c, get_ref_node(ref c.arena, node).node); }
    if (kind == NODE_VAR_ASSIGN) { flow_forget(ref c, get_var_assign_node(ref c.arena, node).name_tok.value, false); }
    if (kind == NODE_FIELD_ASSIGN) {
        let assignment = get_field_assign_node(ref c.arena, node);
        flow_forget(ref c, format_ast_path(ref c, assignment.obj) + "." + assignment.field_name, false);
    }
    if (kind == NODE_PTR_ASSIGN) { c.flow_types = []; }
    if (kind == NODE_WHILE || kind == NODE_FOR || kind == NODE_CATCH) { c.flow_types = []; }
    return result;
}

func ref_check_raw_node(ref c: Compiler, ref state: RefCheck, node: NodeID) -> Bool {
// callee walks can nest inside the AST walk, keep unrelated node locals out of this frame
    if (!has_node(node)) { return false; }
    if (!state.collecting && state.calls.length() > 0) {
        if (state.budget <= 0) {
            ref_error(ref state, ref_body_position(ref c, node), "call a function with unverified storage effects");
            return true;
        }
        state.budget--;
    }
    let kind = node_tag(node);
    if (kind == NODE_BLOCK) { return ref_check_block(ref c, ref state, node); }
    if (kind == NODE_VAR_DECL) {
        return ref_check_var_decl(ref c, ref state, node);
    }
    if (kind == NODE_VAR_ASSIGN) {
        return ref_check_var_assign(ref c, ref state, node);
    }
    if (kind == NODE_FIELD_ASSIGN) {
        let assignment = get_field_assign_node(ref c.arena, node);
        ref_check_node(ref c, ref state, assignment.obj);
        ref_check_node(ref c, ref state, assignment.value);
        let owner = c.struct_id_map.lookup(get_repr_type(ref c, get_expr_type(ref c, assignment.obj)));
        let field = find_field(owner, assignment.field_name);
        if (field is null) { return false; }
        let type = field.type;
        if (state.collecting && ref_storage(ref c, type)) {
            ref_publish(ref state, ref_owner(ref c, ref state, assignment.value));
        }
        ref_check_write(ref c, ref state, type, 0, assignment.pos);
        return false;
    }
    if (kind == NODE_INDEX_ASSIGN) {
        return ref_check_index_assign(ref c, ref state, node);
    }
    if (kind == NODE_CALL) {
        return ref_walk_call(ref c, ref state, node);
    }
    if (kind == NODE_IF) {
        return ref_check_if(ref c, ref state, node);
    }
    if (kind == NODE_WHILE) {
        let loop = get_while_node(ref c.arena, node);
        state.loop_depth++;
        ref_check_node(ref c, ref state, loop.condition);
        flow_apply_guard(ref c, loop.condition, true);
        ref_check_node(ref c, ref state, loop.body);
        state.loop_depth--;
        return false;
    }
    if (kind == NODE_FOR) {
        return ref_check_for(ref c, ref state, node);
    }
    if (kind == NODE_CATCH) {
        let caught = get_catch_node(ref c.arena, node);
        let before = ref_snapshot(ref state);
        let success = ref_check_node(ref c, ref state, caught.stmt);
        let after_success = ref_snapshot(ref state);
        state.slots = before;
        let failure = ref_check_node(ref c, ref state, caught.body);
        ref_merge(ref state, after_success, success, failure);
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
        let short_circuit = kind == NODE_BINOP && (binary.op_tok.type == TOK_AND || binary.op_tok.type == TOK_OR);
        let incoming = flow_copy(c.flow_types);
        if short_circuit { flow_apply_guard(ref c, binary.left, binary.op_tok.type == TOK_AND); }
        ref_check_node(ref c, ref state, binary.right);
        if short_circuit { c.flow_types = flow_intersect(incoming, c.flow_types); }
        if (kind == NODE_BINOP && state.active.length() > 0 &&
            (!ref_scalar_expr(ref c, binary.left) || !ref_scalar_expr(ref c, binary.right))) {
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
        if (state.active.length() > 0 && !ref_scalar_expr(ref c, operand)) {
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
        while (i < literal.elements.length()) {
            ref_check_node(ref c, ref state, literal.elements[i].val);
            if (state.collecting && ref_storage(ref c, get_expr_type(ref c, literal.elements[i].val))) {
                ref_publish(ref state, ref_owner(ref c, ref state, literal.elements[i].val));
            }
            i++;
        }
        return false;
    }
    if (kind == NODE_MAP_LIT) {
        let literal = get_map_lit_node(ref c.arena, node);
        let i = 0;
        while (i < literal.pairs.length()) {
            let pair = literal.pairs[i];
            ref_check_node(ref c, ref state, pair.key);
            ref_check_node(ref c, ref state, pair.value);
            if (state.collecting && ref_storage(ref c, get_expr_type(ref c, pair.value))) {
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

func ref_check_var_decl(ref c: Compiler, ref state: RefCheck, node: NodeID) -> Bool {
    let declaration = get_var_decl_node(ref c.arena, node);
    ref_check_node(ref c, ref state, declaration.value);
    let type = resolve_type(ref c, declaration.type_node);
    let reference = false;
    if (has_node(declaration.value) && node_tag(declaration.value) == NODE_REF &&
        node_tag(get_ref_node(ref c.arena, declaration.value).node) != NODE_SLICE_ACCESS &&
        !is_pointer_type(ref c, type) && type != TYPE_ANYPTR) {
        let target = get_ref_node(ref c.arena, declaration.value).node;
        reference = true;
        if (type == TYPE_AUTO) { type = get_expr_type(ref c, target); }
        if (!state.collecting && node_tag(target) == NODE_INDEX_ACCESS) {
            let access = get_index_access_node(ref c.arena, target);
            let owner = get_repr_type(ref c, get_expr_type(ref c, access.target));
            if (ref_storage(ref c, owner)) {
                state.active.append(RefUse(name=declaration.name_tok.value, owner=ref_owner(ref c, ref state, access.target), slot=ref_owner_slot(ref c, ref state, access.target), element=ref_element(ref c, owner)));
                c.ref_targets.put(UInt32(target), true);
            }
        }
    } else if (type == TYPE_AUTO && has_node(declaration.value)) {
        type = get_expr_type(ref c, declaration.value);
        if (type == 0 && node_tag(declaration.value) == NODE_CALL) {
            let record = ref_constructor(ref c, get_call_node(ref c.arena, declaration.value).callee);
            if ((record is !null)) { type = record.type_id; }
        }
    }
    if (!reference && state.active.length() > 0 && needs_drop(ref c, type) && !ref_plain_drop(ref c, type, 0)) {
        ref_error(ref state, declaration.pos, "create a managed value with unverified drop effects");
    }
    let slot = "ref." + state.frame + "." + UInt32(node);
    flow_forget(ref c, declaration.name_tok.value, false);
    if (ref_storage(ref c, type)) {
        if (reference && node_tag(get_ref_node(ref c.arena, declaration.value).node) == NODE_VAR_ACCESS) {
            let name = get_var_access_node(ref c.arena, get_ref_node(ref c.arena, declaration.value).node).name_tok.value;
            let source = find_symbol(ref c, name);
            if ((source is !null)) { state.slot_refs.put(slot, ref_slot(ref state, source.reg)); }
        }
        ref_set_slot(ref state, slot, ref_owner(ref c, ref state, declaration.value));
    }
    scope_put(c.symbol_table, declaration.name_tok.value, SymbolInfo(reg=slot, type=type, is_const=declaration.is_const, is_reference=reference, origin_type=0, is_const_access=false, is_ref_param=false, func_arg_types=[], arg_names=[], variadic_param=0));
    if ((c.func_ret_map.lookup(type) is !null) && has_node(declaration.value)) {
        // declarations keep a known direct target, assignments clear it conservatively
        let known = ref_call_info(ref c, declaration.value);
        if (node_tag(declaration.value) == NODE_VAR_ACCESS) {
            let source = find_symbol(ref c, get_var_access_node(ref c.arena, declaration.value).name_tok.value);
            if ((source is !null)) { known = state.functions.lookup(source.reg); }
        }
        if ((known is !null)) { state.functions.put(slot, known); }
    }
    return false;
}

func ref_check_var_assign(ref c: Compiler, ref state: RefCheck, node: NodeID) -> Bool {
    let assignment = get_var_assign_node(ref c.arena, node);
    ref_check_node(ref c, ref state, assignment.value);
    let symbol = find_symbol(ref c, assignment.name_tok.value);
    if (symbol is null) { return false; }
    let target: SymbolInfo = symbol;
    state.functions.remove(target.reg);
    let owner = 0;
    if (state.slots.contains_key(ref_slot(ref state, target.reg))) {
        let existing = state.slots.lookup(ref_slot(ref state, target.reg));
        if (existing is !null) { owner = existing; }
    }
    ref_check_write(ref c, ref state, target.type, owner, assignment.pos, ref_slot(ref state, target.reg));
    if (ref_storage(ref c, target.type)) {
        let next = ref_owner(ref c, ref state, assignment.value);
        if (state.collecting && state.loop_depth > 0) { ref_join(ref state, owner, next); }
        ref_set_slot(ref state, target.reg, next);
    }
    return false;
}

func ref_check_index_assign(ref c: Compiler, ref state: RefCheck, node: NodeID) -> Bool {
    let assignment = get_index_assign_node(ref c.arena, node);
    ref_check_node(ref c, ref state, assignment.target);
    ref_check_node(ref c, ref state, assignment.index_node);
    ref_check_node(ref c, ref state, assignment.value);
    let target = get_repr_type(ref c, get_expr_type(ref c, assignment.target));
    if (is_pointer_type(ref c, target)) { return false; }
    let array = c.array_info_map.lookup(target);
    let vector = c.vector_base_map.lookup(target);
    let element = 0;
    if ((array is !null)) { element = array.base_type; }
    if ((vector is !null)) { element = vector.type; }
    if (state.collecting && ref_storage(ref c, element)) {
        ref_publish(ref state, ref_owner(ref c, ref state, assignment.value));
    }
    ref_check_write(ref c, ref state, element, 0, assignment.pos);
    return false;
}

func ref_walk_call(ref c: Compiler, ref state: RefCheck, node: NodeID) -> Bool {
    let call = get_call_node(ref c.arena, node);
    ref_check_node(ref c, ref state, call.callee);
    let active = state.active.length();
    let info: FuncInfo = FuncInfo(name="", base_name="", ret_type=0, arg_types=[], arg_names=[], is_varargs=false, ann_flags=0, compiler_link_name="", abi_name="", mutates_self=false, variadic_param=0, default_args=[], ref_body=NodeID(0U), ref_context=null, ref_bindings=null);
    let candidates = false;
    let probe = 0;
    while (probe < call.args.length()) {
        let arg = call.args[probe];
        if (node_tag(arg.val) == NODE_REF && node_tag(get_ref_node(ref c.arena, arg.val).node) == NODE_INDEX_ACCESS) { candidates = true; }
        probe++;
    }
    if (candidates && !state.collecting) {
        let known = ref_known_call(ref c, ref state, call);
        if (known is !null) { info = known; }
    }
    let arguments = call.args;
    let skip = 0;
    if (!state.collecting && (candidates || state.active.length() > 0)) {
        if (!has_func(info)) {
            let known = ref_known_call(ref c, ref state, call);
            if (known is !null) { info = known; }
        }
        if (candidates && !has_func(info)) {
            let record = c.struct_id_map.lookup(get_repr_type(ref c, get_expr_type(ref c, node)));
            if ((record is !null) && record.is_class) {
                let init = c.func_table.lookup(record.name + "_$init");
                if ((init is !null)) {
                    info = init;
                    skip = 1;
                }
            }
        }
        if (has_func(info) && info.variadic_param == 0 && !info.is_varargs) {
            if (ref_method_call(ref c, call, info)) { skip = 1; }
            let ordered = bind_native_args(arguments, info, skip, call.pos);
            if (has_bound_args(ordered)) { arguments = ordered.ordered; }
        } else if (candidates && !has_func(info)) {
            let signature = c.func_ret_map.lookup(get_expr_type(ref c, call.callee));
            if (!(signature is !null)) { signature = c.method_ret_map.lookup(get_expr_type(ref c, call.callee)); }
            if ((signature is !null)) {
                let ordered = bind_callable_args(arguments, signature, call.pos);
                if (has_bound_args(ordered)) { arguments = ordered.ordered; }
                info = FuncInfo(name="$dynamic", arg_types=signature.func_arg_types, arg_names=signature.arg_names, base_name="", ret_type=0, is_varargs=false, ann_flags=0, compiler_link_name="", abi_name="", mutates_self=false, variadic_param=0, default_args=[], ref_body=NodeID(0U), ref_context=null, ref_bindings=null);
            }
        }
    }
    // lowering loads the receiver before its arguments, keep that selected type
    // without restoring unrelated facts which an argument call can invalidate
    let receiver_type = 0;
    if (has_func(info) && ref_method_call(ref c, call, info)) {
        receiver_type = get_expr_type(ref c, get_field_access_node(ref c.arena, call.callee).obj);
    }
    let i = 0;
    while (i < arguments.length()) {
        let arg = arguments[i];
        ref_check_node(ref c, ref state, arg.val);
        if (!state.collecting && node_tag(arg.val) == NODE_REF && has_func(info)) {
            let param_index = i + skip;
            if (arg.name.length() != 0) {
                param_index = 0;
                while (param_index < info.arg_names.length() && info.arg_names[param_index] != arg.name) { param_index++; }
            }
            if (param_index < info.arg_types.length()) {
                let param: TypeListNode = info.arg_types[param_index];
                let target = get_ref_node(ref c.arena, arg.val).node;
                if (param.pass_mode == PARAM_REF && node_tag(target) == NODE_INDEX_ACCESS) {
                    let access = get_index_access_node(ref c.arena, target);
                    let target_type: Int = get_expr_type(ref c, access.target);
                    if (ref_storage(ref c, target_type)) {
                        if (!ref_stable_owner(ref c, access.target)) {
                            throw_type_error(call.pos, "Cannot pass a reference to storage that may move or be released.");
                        } else {
                            state.active.append(RefUse(name="argument", owner=ref_owner(ref c, ref state, access.target), slot=ref_owner_slot(ref c, ref state, access.target), element=ref_element(ref c, target_type)));
                        }
                    }
                }
            }
        }
        i++;
    }
    ref_check_call(ref c, ref state, call, info, receiver_type);
    while (state.active.length() > active) { state.active.drop(); }
    return false;
}

func ref_check_if(ref c: Compiler, ref state: RefCheck, node: NodeID) -> Bool {
    let branch = get_if_node(ref c.arena, node);
    ref_check_node(ref c, ref state, branch.condition);
    let selected = fold_target_cond(ref c, branch.condition);
    if (node_tag(branch.condition) == NODE_BOOL) { selected = get_bool_node(ref c.arena, branch.condition).value; }
    if (selected == 1) { return ref_check_node(ref c, ref state, branch.body); }
    if (selected == 0) { return ref_check_node(ref c, ref state, branch.else_body); }
    let before = ref_snapshot(ref state);
    let incoming = flow_copy(c.flow_types);
    flow_apply_guard(ref c, branch.condition, true);
    let left = ref_check_node(ref c, ref state, branch.body);
    let after_left = ref_snapshot(ref state);
    let left_facts = flow_copy(c.flow_types);
    state.slots = before;
    c.flow_types = flow_copy(incoming);
    flow_apply_guard(ref c, branch.condition, false);
    let right = ref_check_node(ref c, ref state, branch.else_body);
    if (!left) {
        if right { c.flow_types = left_facts; }
        else { c.flow_types = flow_intersect(left_facts, c.flow_types); }
    }
    ref_merge(ref state, after_left, left, right);
    return left && right;
}

func ref_check_for(ref c: Compiler, ref state: RefCheck, node: NodeID) -> Bool {
    let loop = get_for_node(ref c.arena, node);
    let saved = c.symbol_table;
    let parent = c.scope_stack.length();
    c.scope_stack.append(saved);
    c.symbol_table = Scope(table=Dict(), parent=parent, gc_vars=[], depth=saved.depth + 1);
    let active = state.active.length();
    ref_check_node(ref c, ref state, loop.init);
    state.loop_depth++;
    ref_check_node(ref c, ref state, loop.cond);
    flow_apply_guard(ref c, loop.cond, true);
    ref_check_node(ref c, ref state, loop.body);
    ref_check_node(ref c, ref state, loop.step);
    state.loop_depth--;
    while (state.active.length() > active) { state.active.drop(); }
    c.symbol_table = saved;
    c.scope_stack.drop();
    return false;
}


func ref_body_position(ref c: Compiler, node: NodeID) -> Position {
    if (node_tag(node) == NODE_BLOCK) {
        let block = get_block_node(ref c.arena, node);
        if (block.stmts.length() > 0) { return ref_body_position(ref c, block.stmts[0]); }
    }
    if (node_tag(node) == NODE_CALL) { return get_call_node(ref c.arena, node).pos; }
    if (node_tag(node) == NODE_VAR_DECL) { return get_var_decl_node(ref c.arena, node).pos; }
    if (node_tag(node) == NODE_RETURN) { return get_return_node(ref c.arena, node).pos; }
    return no_position();
}

func check_body_refs(ref c: Compiler, body: NodeID, found_inputs: Optional(Dict(String, SymbolInfo))) -> Bool {
// this walk has its own lexical tables, lowering must retain its real binding addresses
    if (found_inputs is null) {
        throw_internal_compiler_error(no_position(), "Reference analysis requires an active scope.");
        return false;
    }
    let inputs: Dict(String, SymbolInfo) = found_inputs;
    if (!has_index_refs(ref c)) { return true; }
    let file = ref_body_file(ref c, body);
    if (file.length() > 0 && !c.ref_files.contains_key(file)) { return true; }

    let errors = GLOBAL_ERROR_COUNT;
    let scope = c.symbol_table;
    let stack = c.scope_stack;
    let hoist = c.hoist_scope;
    let hoist_stack = c.hoist_scope_stack;
    let facts = c.flow_types;
    let exposed = c.flow_exposed;
    c.symbol_table = Scope(table=inputs, parent=-1, gc_vars=[], depth=0);
    c.scope_stack = [];
    c.hoist_scope = Scope(table=null, parent=0, gc_vars=[], depth=0);
    c.hoist_scope_stack = [];
    let state = RefCheck(active=[], parents=[0], escaped=[true], slots=Dict(), slot_names=[], slot_refs=Dict(), allocations=Dict(), collecting=true, calls=[], budget=20000, functions=Dict(), loop_depth=0, frame=0, next_frame=0);
    c.flow_types = [];
    c.flow_exposed = [];
    ref_check_node(ref c, ref state, body);
    state.collecting = false;
    c.flow_types = [];
    c.flow_exposed = [];
    ref_check_node(ref c, ref state, body);
    c.flow_types = facts;
    c.flow_exposed = exposed;
    c.symbol_table = scope;
    c.scope_stack = stack;
    c.hoist_scope = hoist;
    c.hoist_scope_stack = hoist_stack;
    return GLOBAL_ERROR_COUNT == errors;
}
