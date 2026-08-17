// compiler/validation.wl
import * from "../frontend/ast.wl"
import * from "context.wl"
import * from "../frontend/tokens.wl"
import * from "../frontend/diagnostics.wl"

func expr_root_name(node: Struct) -> String {
    if (node is null) { return ""; }
    let base: BaseNode = node;
    if (base.type == NODE_VAR_ACCESS) { let value: VarAccessNode = node; return value.name_tok.value; }
    if (base.type == NODE_FIELD_ACCESS) { let value: FieldAccessNode = node; return expr_root_name(value.obj); }
    if (base.type == NODE_INDEX_ACCESS) { let value: IndexAccessNode = node; return expr_root_name(value.target); }
    if (base.type == NODE_SLICE_ACCESS) { let value: SliceAccessNode = node; return expr_root_name(value.target); }
    if (base.type == NODE_DEREF) { let value: DerefNode = node; return expr_root_name(value.node); }
    return "";
}

func const_access_root(c: Compiler, node: Struct) -> String {
    let name: String = expr_root_name(node);
    if (name.length() == 0) { return ""; }
    let info: SymbolInfo = find_symbol(c, name);
    if (info is !null && (info.is_const || info.is_const_access)) { return name; }
    return "";
}

func reject_const_write(c: Compiler, node: Struct, pos: Position) -> Bool {
    let name: String = const_access_root(c, node);
    if (name.length() == 0) { return false; }
    throw_type_error(pos, "Cannot modify value through const access '" + name + "'");
    return true;
}

func method_mutates_self(node: Struct) -> Bool {
    if (node is null) { return false; }
    let base: BaseNode = node;
    if (base.type == NODE_FIELD_ASSIGN) { let value: FieldAssignNode = node; return expr_root_name(value.obj) == "self" || expr_root_name(value.value) == "self"; }
    if (base.type == NODE_INDEX_ASSIGN) { let value: IndexAssignNode = node; return expr_root_name(value.target) == "self" || expr_root_name(value.value) == "self"; }
    if (base.type == NODE_PTR_ASSIGN) { let value: PtrAssignNode = node; return expr_root_name(value.pointer) == "self" || expr_root_name(value.value) == "self"; }
    if (base.type == NODE_POSTFIX) { let value: PostfixOpNode = node; return expr_root_name(value.node) == "self"; }
    if (base.type == NODE_REF) { let value: RefNode = node; return expr_root_name(value.node) == "self"; }
    if (base.type == NODE_VAR_DECL) { let value: VarDeclareNode = node; return expr_root_name(value.value) == "self"; }
    if (base.type == NODE_VAR_ASSIGN) { let value: VarAssignNode = node; return expr_root_name(value.value) == "self"; }
    if (base.type == NODE_CALL) {
        let call: CallNode = node;
        let callee: BaseNode = call.callee;
        if (callee is !null && callee.type == NODE_FIELD_ACCESS) { let field: FieldAccessNode = call.callee; if (expr_root_name(field.obj) == "self") { return true; } }
        let i: Int = 0;
        while (call.args is !null && i < call.args.length()) { let arg: ArgNode = call.args[i]; if (expr_root_name(arg.val) == "self") { return true; } i += 1; }
    }
    if (base.type == NODE_FUNC_DEF) { let value: FunctionDefNode = node; return method_mutates_self(value.body); }
    if (base.type == NODE_BLOCK) {
        let block: BlockNode = node;
        let i: Int = 0;
        while (block.stmts is !null && i < block.stmts.length()) { if (method_mutates_self(block.stmts[i])) { return true; } i += 1; }
    }
    if (base.type == NODE_IF) { let value: IfNode = node; return method_mutates_self(value.body) || method_mutates_self(value.else_body); }
    if (base.type == NODE_WHILE) { let value: WhileNode = node; return method_mutates_self(value.body); }
    if (base.type == NODE_FOR) { let value: ForNode = node; return method_mutates_self(value.init) || method_mutates_self(value.step) || method_mutates_self(value.body); }
    if (base.type == NODE_CATCH) { let value: CatchNode = node; return method_mutates_self(value.stmt) || method_mutates_self(value.body); }
    return false;
}

func check_duplicate_params(params: Vector(Struct), owner: String, pos: Position) -> Bool {
    let seen: Dict(String, StringConstant) = Dict();
    let i: Int = 0;
    while (params is !null && i < params.length()) {
        let param: ParamNode = params[i];
        let name: String = param.name_tok.value;
        if (seen.contains_key(name)) { throw_name_error(param.pos, "Duplicate parameter '" + name + "' in " + owner); return false; }
        seen.put(name, StringConstant(id=0, value=name));
        i += 1;
    }
    return true;
}

func same_method_signature(parent: FuncInfo, child: FuncInfo) -> Bool {
    if (parent is null || child is null || parent.ret_type != child.ret_type) { return false; }
    let parent_len: Int = 0; if (parent.arg_types is !null) { parent_len = parent.arg_types.length(); }
    let child_len: Int = 0; if (child.arg_types is !null) { child_len = child.arg_types.length(); }
    if (parent_len != child_len) { return false; }
    let i: Int = 1;
    while (i < parent_len) { let a: TypeListNode = parent.arg_types[i]; let b: TypeListNode = child.arg_types[i]; if (a.type != b.type) { return false; } i += 1; }
    return true;
}

func add_interface_type(c: Compiler, list: Vector(Struct), type_id: Int, pos: Position) -> Bool {
    let info: StructInfo = c.struct_id_map.lookup("" + type_id);
    if (info is null || !info.is_interface) {
        throw_type_error(pos, "Type " + get_type_name(c, type_id) + " is not an interface.");
        return false;
    }
    let i: Int = 0;
    while (i < list.length()) {
        let item: TypeListNode = list[i];
        if (item.type == type_id) { return true; }
        i++;
    }
    list.append(TypeListNode(type=type_id));
    return true;
}

func add_interface(c: Compiler, list: Vector(Struct), node: Struct, pos: Position) -> Bool {
    return add_interface_type(c, list, resolve_type(c, node), pos);
}

func class_has_interface(c: Compiler, class_info: StructInfo, target: StructInfo) -> Bool {
    let current: StructInfo = class_info;
    while (current is !null) {
        let i: Int = 0;
        while (current.interfaces is !null && i < current.interfaces.length()) {
            let item: TypeListNode = current.interfaces[i];
            if (item.type == target.type_id) { return true; }
            i += 1;
        }
        if (current.parent_id == 0) { break; }
        current = c.struct_id_map.lookup("" + current.parent_id);
    }
    return false;
}

func is_unsuffix_int_literal(node: Struct) -> Bool {
    if (node is null) { return false; }
    let base: BaseNode = node;
    if (base.type != NODE_INT) { return false; }
    let value: IntNode = node;
    let text: String = value.tok.value;
    return !text.ends_with("u") && !text.ends_with("U") && !text.ends_with("ul") && !text.ends_with("UL") && !text.ends_with("ull") && !text.ends_with("ULL");
}

func bind_call_args(args: Vector(Struct), names: Vector(String), skip: Int, pos: Position) -> Vector(Struct) {
    let expected: Int = 0; if (names is !null) { expected = names.length() - skip; }
    let count: Int = 0; if (args is !null) { count = args.length(); }
    if (count != expected) { throw_type_error(pos, "Expected " + expected + " arguments, got " + count); return null; }
    let ordered: Vector(Struct) = [];
    let i: Int = 0;
    while (i < expected) { ordered.append(null); i += 1; }
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
        if (arg.name is null || arg.name.length() == 0) {
            if saw_named {
                throw_invalid_syntax(pos, "Positional argument cannot follow a named argument");
                return null;
            }
            target = next_positional;
            next_positional += 1;
        } else {
            saw_named = true;
            let name_index: Int = skip;
            while (name_index < names.length()) { if (names[name_index] == arg.name) { target = name_index - skip; break; } name_index += 1; }
            if (target < 0) { throw_name_error(pos, "Unknown argument '" + arg.name + "'"); return null; }
        }
        if (target < 0 || target >= expected) { throw_type_error(pos, "Too many arguments"); return null; }
        if (ordered[target] is !null) { let duplicate: String = names[target + skip]; throw_name_error(pos, "Argument '" + duplicate + "' is specified more than once"); return null; }
        ordered[target] = arg;
        i += 1;
    }
    i = 0;
    while (i < expected) { if (ordered[i] is null) { throw_type_error(pos, "Missing argument '" + names[i + skip] + "'"); return null; } i += 1; }
    return ordered;
}

func bind_native_args(args: Vector(Struct), info: FuncInfo, skip: Int, pos: Position) -> BoundCallArgs {
    let names: Vector(String) = info.arg_names;
    let expected: Int = names.length() - skip;
    let pack_index: Int = info.variadic_param - 1;
    let ordered: Vector(Struct) = [];
    let packed: Vector(Struct) = [];
    let i: Int = 0;
    while (i < expected) { ordered.append(null); i += 1; }

    let next_positional: Int = 0;
    let saw_named: Bool = false;
    i = 0;
    while (args is !null && i < args.length()) {
        let arg: ArgNode = args[i];
        if (arg.name is null || arg.name.length() == 0) {
            if saw_named {
                throw_invalid_syntax(pos, "Positional argument cannot follow a named argument.");
                return null;
            }
            if (pack_index >= 0 && next_positional >= pack_index) {
                packed.append(arg);
                next_positional = pack_index;
            } else {
                if (arg.is_spread) {
                    throw_invalid_syntax(pos, "A spread argument requires a variadic parameter.");
                    return null;
                }
                if (next_positional >= expected) {
                    throw_type_error(pos, "Too many arguments.");
                    return null;
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
                return null;
            }
            if (target == pack_index) {
                throw_type_error(pos, "Variadic parameter '" + arg.name + "' must be supplied with positional arguments.");
                return null;
            }
            if (ordered[target] is !null) {
                throw_name_error(pos, "Argument '" + arg.name + "' is specified more than once.");
                return null;
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
        if (ordered[i] is null) {
            let default_index: Int = i;
            if (info.default_args is !null && default_index < info.default_args.length() && info.default_args[default_index] is !null) {
                ordered[i] = ArgNode(val=info.default_args[default_index], name=names[i + skip], is_spread=false);
            } else {
                throw_type_error(pos, "Missing argument '" + names[i + skip] + "'.");
                return null;
            }
        }
        i += 1;
    }
    return BoundCallArgs(ordered=ordered, variadic=packed);
}

func reject_named_args(args: Vector(Struct), pos: Position, target: String) -> Bool {
    let i: Int = 0;
    while (args is !null && i < args.length()) {
        let arg: ArgNode = args[i];
        if (arg.name is !null && arg.name.length() > 0) { throw_invalid_syntax(pos, "Named arguments are not available when calling " + target); return true; }
        i += 1;
    }
    return false;
}

