// compiler/initialization.wl
import * from "../frontend/ast.wl"
import * from "context.wl"
import * from "../frontend/diagnostics.wl"
import * from "target_eval.wl"

struct InitFlow(
    initialized: Vector(String),
    terminates: Bool
)

struct LocalInitScope(
    table: Dict(String, SymbolInfo),
    parent: LocalInitScope,
    declarations: Vector(Struct)
)

func init_has(initialized: Vector(String), name: String) -> Bool {
    let i: Int = 0;
    while (i < initialized.length()) {
        if (initialized[i] == name) { return true; }
        i += 1;
    }
    return false;
}

func init_add(initialized: Vector(String), name: String) -> Void {
    if (!init_has(initialized, name)) { initialized.append(name); }
}

func init_copy(initialized: Vector(String)) -> Vector(String) {
    let copy: Vector(String) = [];
    let i: Int = 0;
    while (i < initialized.length()) {
        copy.append(initialized[i]);
        i += 1;
    }
    return copy;
}

func init_intersection(left: Vector(String), right: Vector(String)) -> Vector(String) {
// only assignments made on both incoming paths remain definite
    let result: Vector(String) = [];
    let i: Int = 0;
    while (i < left.length()) {
        if (init_has(right, left[i])) { result.append(left[i]); }
        i += 1;
    }
    return result;
}

func init_without(initialized: Vector(String), removed: Vector(String)) -> Vector(String) {
    let result: Vector(String) = [];
    let i: Int = 0;
    while (i < initialized.length()) {
        if (!init_has(removed, initialized[i])) { result.append(initialized[i]); }
        i += 1;
    }
    return result;
}

func local_init_key(node: VarDeclareNode) -> String {
    return "" + node.alloc_id;
}

func bind_local_init(scope: LocalInitScope, node: VarDeclareNode) -> Void {
    scope.table.put(node.name_tok.value, SymbolInfo(reg="", type=node.alloc_id + 1, origin_type=0, is_const=node.is_const));
    scope.declarations.append(node);
}

func lookup_local_init(scope: LocalInitScope, name: String) -> String {
    let current: LocalInitScope = scope;
    while (current is !null) {
        let info: SymbolInfo = current.table.lookup(name);
        if (info is !null) {
            if (info.type <= 0) { return ""; }
            return "" + (info.type - 1);
        }
        current = current.parent;
    }
    return "";
}

func read_local_init(scope: LocalInitScope, initialized: Vector(String), name: String, pos: Position) -> Void {
    let key: String = lookup_local_init(scope, name);
    if (key.length() == 0 || init_has(initialized, key)) { return; }
    throw_missing_initializer(pos, "Variable '" + name + "' may be used before initialization.");
    init_add(initialized, key);
}

func merge_local_init(before: Vector(String), success: InitFlow, failure: InitFlow) -> InitFlow {
// a terminating edge contributes no state to the code that follows
    if (success.terminates && failure.terminates) { return InitFlow(before, true); }
    if (success.terminates) { return InitFlow(failure.initialized, false); }
    if (failure.terminates) { return InitFlow(success.initialized, false); }
    return InitFlow(init_intersection(success.initialized, failure.initialized), false);
}

func check_local_init_block(c: Compiler, node: BlockNode, parent: LocalInitScope, initialized: Vector(String)) -> InitFlow {
    let scope: LocalInitScope = LocalInitScope(table=Dict(), parent=parent, declarations=[]);
    let state: Vector(String) = initialized;
    let terminates: Bool = false;
    let i: Int = 0;
    while (node.stmts is !null && i < node.stmts.length()) {
        let flow: InitFlow = check_local_init_node(c, node.stmts[i], scope, state);
        state = flow.initialized;
        if (flow.terminates) { terminates = true; break; }
        i += 1;
    }

    let local_keys: Vector(String) = [];
    i = 0;
    while (i < scope.declarations.length()) {
        let declaration: VarDeclareNode = scope.declarations[i];
        let key: String = local_init_key(declaration);
        local_keys.append(key);
        if (!terminates && !init_has(state, key)) {
            throw_missing_initializer(declaration.pos, "Local variable '" + declaration.name_tok.value + "' is not initialized on every path.");
            init_add(state, key);
        }
        i += 1;
    }
    return InitFlow(init_without(state, local_keys), terminates);
}

func check_local_init_node(c: Compiler, node: Struct, scope: LocalInitScope, initialized: Vector(String)) -> InitFlow {
// each result carries the definite set together with control-flow termination
    if (node is null) { return InitFlow(initialized, false); }
    let base: BaseNode = node;

    if (base.type == NODE_BLOCK) { return check_local_init_block(c, node, scope, initialized); }
    if (base.type == NODE_VAR_ACCESS) {
        let access: VarAccessNode = node;
        read_local_init(scope, initialized, access.name_tok.value, access.pos);
        return InitFlow(initialized, false);
    }
    if (base.type == NODE_VAR_DECL) {
        let declaration: VarDeclareNode = node;
        let value_flow: InitFlow = check_local_init_node(c, declaration.value, scope, initialized);
        bind_local_init(scope, declaration);
        init_add(value_flow.initialized, local_init_key(declaration));
        return InitFlow(value_flow.initialized, false);
    }
    if (base.type == NODE_VAR_ASSIGN) {
        let assignment: VarAssignNode = node;
        let value_flow: InitFlow = check_local_init_node(c, assignment.value, scope, initialized);
        let key: String = lookup_local_init(scope, assignment.name_tok.value);
        if (key.length() > 0) { init_add(value_flow.initialized, key); }
        return InitFlow(value_flow.initialized, false);
    }
    if (base.type == NODE_CATCH) {
        let caught: CatchNode = node;
        let before: Vector(String) = init_copy(initialized);
        let success: InitFlow = check_local_init_node(c, caught.stmt, scope, init_copy(initialized));
        let failure: InitFlow = check_local_init_block(c, caught.body, scope, init_copy(before));
        return merge_local_init(before, success, failure);
    }
    if (base.type == NODE_IF) {
        let branch: IfNode = node;
        let condition_flow: InitFlow = check_local_init_node(c, branch.condition, scope, initialized);
        let selected: Int = fold_target_cond(c, branch.condition);
        let condition: BaseNode = branch.condition;
        if (condition is !null && condition.type == NODE_BOOL) {
            let boolean: BooleanNode = branch.condition;
            selected = boolean.value;
        }
        if (selected == 1) { return check_local_init_node(c, branch.body, scope, condition_flow.initialized); }
        if (selected == 0) { return check_local_init_node(c, branch.else_body, scope, condition_flow.initialized); }
        let then_flow: InitFlow = check_local_init_node(c, branch.body, scope, init_copy(condition_flow.initialized));
        let else_flow: InitFlow = InitFlow(init_copy(condition_flow.initialized), false);
        if (branch.else_body is !null) { else_flow = check_local_init_node(c, branch.else_body, scope, init_copy(condition_flow.initialized)); }
        return merge_local_init(condition_flow.initialized, then_flow, else_flow);
    }
    if (base.type == NODE_WHILE) {
        let loop: WhileNode = node;
        let condition_flow: InitFlow = check_local_init_node(c, loop.condition, scope, initialized);
        check_local_init_node(c, loop.body, scope, init_copy(condition_flow.initialized));
        return InitFlow(condition_flow.initialized, must_terminate(c, node));
    }
    if (base.type == NODE_FOR) {
        let loop: ForNode = node;
        let state: Vector(String) = initialized;
        if (loop.init is !null) { state = check_local_init_node(c, loop.init, scope, state).initialized; }
        state = check_local_init_node(c, loop.cond, scope, state).initialized;
        let body_flow: InitFlow = check_local_init_node(c, loop.body, scope, init_copy(state));
        if (!body_flow.terminates) { check_local_init_node(c, loop.step, scope, body_flow.initialized); }
        return InitFlow(state, must_terminate(c, node));
    }
    if (base.type == NODE_RETURN) {
        let statement: ReturnNode = node;
        check_local_init_node(c, statement.value, scope, initialized);
        return InitFlow(initialized, true);
    }
    if (base.type == NODE_THROW) {
        let statement: ThrowNode = node;
        check_local_init_node(c, statement.value, scope, initialized);
        return InitFlow(initialized, true);
    }
    if (base.type == NODE_BREAK || base.type == NODE_CONTINUE) { return InitFlow(initialized, true); }
    if (base.type == NODE_BINOP || base.type == NODE_IS || base.type == NODE_IS_NOT) {
        let binary: BinOpNode = node;
        let left_flow: InitFlow = check_local_init_node(c, binary.left, scope, initialized);
        return check_local_init_node(c, binary.right, scope, left_flow.initialized);
    }
    if (base.type == NODE_UNARYOP) {
        let unary: UnaryOpNode = node;
        return check_local_init_node(c, unary.node, scope, initialized);
    }
    if (base.type == NODE_POSTFIX) {
        let postfix: PostfixOpNode = node;
        return check_local_init_node(c, postfix.node, scope, initialized);
    }
    if (base.type == NODE_REF) {
        let reference: RefNode = node;
        return check_local_init_node(c, reference.node, scope, initialized);
    }
    if (base.type == NODE_DEREF) {
        let dereference: DerefNode = node;
        return check_local_init_node(c, dereference.node, scope, initialized);
    }
    if (base.type == NODE_TRY_UNWRAP) {
        let unwrap: TryUnwrapNode = node;
        return check_local_init_node(c, unwrap.expr, scope, initialized);
    }
    if (base.type == NODE_CALL) {
        let call: CallNode = node;
        let state: Vector(String) = check_local_init_node(c, call.callee, scope, initialized).initialized;
        let i: Int = 0;
        while (call.args is !null && i < call.args.length()) {
            let arg: ArgNode = call.args[i];
            state = check_local_init_node(c, arg.val, scope, state).initialized;
            i += 1;
        }
        return InitFlow(state, false);
    }
    if (base.type == NODE_FIELD_ACCESS) {
        let access: FieldAccessNode = node;
        return check_local_init_node(c, access.obj, scope, initialized);
    }
    if (base.type == NODE_FIELD_ASSIGN) {
        let assignment: FieldAssignNode = node;
        let object_flow: InitFlow = check_local_init_node(c, assignment.obj, scope, initialized);
        return check_local_init_node(c, assignment.value, scope, object_flow.initialized);
    }
    if (base.type == NODE_PTR_ASSIGN) {
        let assignment: PtrAssignNode = node;
        let pointer_flow: InitFlow = check_local_init_node(c, assignment.pointer, scope, initialized);
        return check_local_init_node(c, assignment.value, scope, pointer_flow.initialized);
    }
    if (base.type == NODE_INDEX_ACCESS) {
        let access: IndexAccessNode = node;
        let target_flow: InitFlow = check_local_init_node(c, access.target, scope, initialized);
        return check_local_init_node(c, access.index_node, scope, target_flow.initialized);
    }
    if (base.type == NODE_INDEX_ASSIGN) {
        let assignment: IndexAssignNode = node;
        let target_flow: InitFlow = check_local_init_node(c, assignment.target, scope, initialized);
        let index_flow: InitFlow = check_local_init_node(c, assignment.index_node, scope, target_flow.initialized);
        return check_local_init_node(c, assignment.value, scope, index_flow.initialized);
    }
    if (base.type == NODE_SLICE_ACCESS) {
        let access: SliceAccessNode = node;
        let state: Vector(String) = check_local_init_node(c, access.target, scope, initialized).initialized;
        state = check_local_init_node(c, access.start_idx, scope, state).initialized;
        return check_local_init_node(c, access.end_idx, scope, state);
    }
    if (base.type == NODE_VECTOR_LIT) {
        let vector: VectorLitNode = node;
        let state: Vector(String) = initialized;
        let i: Int = 0;
        while (vector.elements is !null && i < vector.elements.length()) {
            let element: ArgNode = vector.elements[i];
            state = check_local_init_node(c, element.val, scope, state).initialized;
            i += 1;
        }
        return InitFlow(state, false);
    }
    if (base.type == NODE_MAP_LIT) {
        let map: MapLitNode = node;
        let state: Vector(String) = initialized;
        let i: Int = 0;
        while (map.pairs is !null && i < map.pairs.length()) {
            let pair: MapPairNode = map.pairs[i];
            state = check_local_init_node(c, pair.key, scope, state).initialized;
            state = check_local_init_node(c, pair.value, scope, state).initialized;
            i += 1;
        }
        return InitFlow(state, false);
    }
    if (base.type == NODE_FUNC_DEF) {
        let function: FunctionDefNode = node;
        let captures: CaptureScope = CaptureScope(local_vars=Dict(), captured_vars=Dict(), captured_list=[]);
        let i: Int = 0;
        while (function.params is !null && i < function.params.length()) {
            let param: ParamNode = function.params[i];
            captures.local_vars.put(param.name_tok.value, TypeListNode(type=1));
            i += 1;
        }
        analyze_captures(function.body, captures);
        i = 0;
        while (i < captures.captured_list.length()) {
            read_local_init(scope, initialized, captures.captured_list[i], function.pos);
            i += 1;
        }
        return InitFlow(initialized, false);
    }
    return InitFlow(initialized, false);
}

func check_local_init(c: Compiler, body: Struct) -> Void {
    if (body is null) { return; }
    let root: LocalInitScope = LocalInitScope(table=Dict(), parent=null, declarations=[]);
    check_local_init_block(c, body, root, []);
}

func init_complete(required: Vector(String), initialized: Vector(String)) -> Bool {
    let i: Int = 0;
    while (i < required.length()) {
        if (!init_has(initialized, required[i])) { return false; }
        i += 1;
    }
    return true;
}

func init_require_complete(class_name: String, required: Vector(String), initialized: Vector(String), pos: Position) -> Bool {
    let i: Int = 0;
    while (i < required.length()) {
        let name: String = required[i];
        if (!init_has(initialized, name)) {
            if (name == "$super") {
                throw_missing_initializer(
                    pos,
                    "Constructor for class '" + class_name +
                    "' must call super.init(...) before returning."
                );
            } else {
                throw_missing_initializer(
                    pos,
                    "Field '" + name + "' is not initialized on every path through '" +
                    class_name + ".init'."
                );
            }
            return false;
        }
        i += 1;
    }
    return true;
}

func init_is_self(node: Struct) -> Bool {
    if (node is null) { return false; }
    let base: BaseNode = node;
    if (base.type != NODE_VAR_ACCESS) { return false; }
    let access: VarAccessNode = node;
    return access.name_tok.value == "self";
}

func class_requires_initialization(c: Compiler, info: StructInfo) -> Bool {
    if (info is null || !info.is_class || info.init_body is null) {
        return false;
    }

    let class_node: ClassDefNode = info.init_body;
    let fields: Vector(Struct) = class_node.fields;
    let i: Int = 0;
    while (fields is !null && i < fields.length()) {
        let field: VarDeclareNode = fields[i];
        if (field.value is null) { return true; }
        i += 1;
    }

    if (info.parent_id != 0) {
        let parent: StructInfo = c.struct_id_map.lookup("" + info.parent_id);
        return class_requires_initialization(c, parent);
    }
    return false;
}

func check_init_node(c: Compiler, class_name: String, node: Struct, required: Vector(String), known_fields: Vector(String), initialized: Vector(String)) -> InitFlow {
// field initialization uses the same forward meet as locals, with self reads checked here
    if (node is null) { return InitFlow(initialized, false); }
    let base: BaseNode = node;

    if (base.type == NODE_BLOCK) {
        let block: BlockNode = node;
        let state: Vector(String) = initialized;
        let i: Int = 0;
        while (block.stmts is !null && i < block.stmts.length()) {
            let flow: InitFlow = check_init_node(
                c, class_name, block.stmts[i], required, known_fields, state
            );
            state = flow.initialized;
            if (flow.terminates) { return InitFlow(state, true); }
            i += 1;
        }
        return InitFlow(state, false);
    }

    if (base.type == NODE_IF) {
        let branch: IfNode = node;
        check_init_node(
            c, class_name, branch.condition, required, known_fields, initialized
        );

        let selected: Int = fold_target_cond(c, branch.condition);
        let condition: BaseNode = branch.condition;
        if (condition is !null && condition.type == NODE_BOOL) {
            let boolean: BooleanNode = branch.condition;
            selected = boolean.value;
        }
        if (selected == 1) {
            return check_init_node(
                c,
                class_name,
                branch.body,
                required,
                known_fields,
                initialized
            );
        }
        if (selected == 0) {
            return check_init_node(
                c,
                class_name,
                branch.else_body,
                required,
                known_fields,
                initialized
            );
        }

        let then_flow: InitFlow = check_init_node(
            c,
            class_name,
            branch.body,
            required,
            known_fields,
            init_copy(initialized)
        );
        let else_flow: InitFlow = InitFlow(init_copy(initialized), false);
        if (branch.else_body is !null) {
            else_flow = check_init_node(
                c,
                class_name,
                branch.else_body,
                required,
                known_fields,
                init_copy(initialized)
            );
        }

        if (then_flow.terminates && else_flow.terminates) {
            return InitFlow(initialized, true);
        }
        if (then_flow.terminates) {
            return InitFlow(else_flow.initialized, false);
        }
        if (else_flow.terminates) {
            return InitFlow(then_flow.initialized, false);
        }
        return InitFlow(
            init_intersection(then_flow.initialized, else_flow.initialized),
            false
        );
    }

    if (base.type == NODE_WHILE) {
        let loop: WhileNode = node;
        check_init_node(
            c, class_name, loop.condition, required, known_fields, initialized
        );
        check_init_node(
            c,
            class_name,
            loop.body,
            required,
            known_fields,
            init_copy(initialized)
        );
        return InitFlow(initialized, must_terminate(c, node));
    }

    if (base.type == NODE_FOR) {
        let loop: ForNode = node;
        let state: Vector(String) = initialized;
        if (loop.init is !null) {
            let init_flow: InitFlow = check_init_node(
                c, class_name, loop.init, required, known_fields, state
            );
            state = init_flow.initialized;
        }
        check_init_node(c, class_name, loop.cond, required, known_fields, state);
        check_init_node(
            c,
            class_name,
            loop.body,
            required,
            known_fields,
            init_copy(state)
        );
        check_init_node(
            c,
            class_name,
            loop.step,
            required,
            known_fields,
            init_copy(state)
        );
        return InitFlow(state, must_terminate(c, node));
    }

    if (base.type == NODE_CATCH) {
        let caught: CatchNode = node;
        let success: InitFlow = check_init_node(
            c,
            class_name,
            caught.stmt,
            required,
            known_fields,
            init_copy(initialized)
        );
        let failure: InitFlow = check_init_node(
            c,
            class_name,
            caught.body,
            required,
            known_fields,
            init_copy(initialized)
        );
        if (success.terminates && failure.terminates) {
            return InitFlow(initialized, true);
        }
        if (success.terminates) { return InitFlow(failure.initialized, false); }
        if (failure.terminates) { return InitFlow(success.initialized, false); }
        return InitFlow(
            init_intersection(success.initialized, failure.initialized),
            false
        );
    }

    if (base.type == NODE_RETURN) {
        let return_node: ReturnNode = node;
        check_init_node(
            c, class_name, return_node.value, required, known_fields, initialized
        );
        init_require_complete(class_name, required, initialized, return_node.pos);
        return InitFlow(initialized, true);
    }

    if (base.type == NODE_THROW) {
        let thrown: ThrowNode = node;
        check_init_node(
            c, class_name, thrown.value, required, known_fields, initialized
        );
        return InitFlow(initialized, true);
    }

    if (base.type == NODE_BREAK || base.type == NODE_CONTINUE) {
        return InitFlow(initialized, true);
    }

    if (base.type == NODE_FIELD_ASSIGN) {
        let assignment: FieldAssignNode = node;
        check_init_node(
            c, class_name, assignment.value, required, known_fields, initialized
        );
        if (init_is_self(assignment.obj)) {
            if (init_has(required, "$super") &&
                !init_has(initialized, "$super")) {
                throw_missing_initializer(
                    assignment.pos,
                    "Call super.init(...) before initializing fields of '" +
                    class_name + "'."
                );
                init_add(initialized, "$super");
            }
            if (init_has(known_fields, assignment.field_name)) {
                init_add(initialized, assignment.field_name);
            }
            return InitFlow(initialized, false);
        }
        check_init_node(
            c, class_name, assignment.obj, required, known_fields, initialized
        );
        return InitFlow(initialized, false);
    }

    if (base.type == NODE_FIELD_ACCESS) {
        let access: FieldAccessNode = node;
        if (init_is_self(access.obj)) {
            if (init_has(known_fields, access.field_name)) {
                if (!init_has(initialized, access.field_name)) {
                    throw_missing_initializer(
                        access.pos,
                        "Field '" + access.field_name +
                        "' is read before it is initialized."
                    );
                }
            } else if (!init_complete(required, initialized)) {
                throw_missing_initializer(
                    access.pos,
                    "Cannot use 'self' before all fields of '" +
                    class_name + "' are initialized."
                );
            }
            return InitFlow(initialized, false);
        }
        check_init_node(
            c, class_name, access.obj, required, known_fields, initialized
        );
        return InitFlow(initialized, false);
    }

    if (base.type == NODE_CALL) {
        let call: CallNode = node;
        let is_super_init: Bool = false;
        if (call.callee is !null) {
            let callee_base: BaseNode = call.callee;
            if (callee_base.type == NODE_FIELD_ACCESS) {
                let member: FieldAccessNode = call.callee;
                if (member.field_name == "init" && member.obj is !null) {
                    let owner: BaseNode = member.obj;
                    is_super_init = owner.type == NODE_SUPER;
                }
            }
        }

        let i: Int = 0;
        while (call.args is !null && i < call.args.length()) {
            let arg: ArgNode = call.args[i];
            check_init_node(
                c, class_name, arg.val, required, known_fields, initialized
            );
            i += 1;
        }

        if is_super_init {
            init_add(initialized, "$super");
        } else {
            check_init_node(
                c, class_name, call.callee, required, known_fields, initialized
            );
        }
        return InitFlow(initialized, false);
    }

    if (base.type == NODE_VAR_ACCESS) {
        let access: VarAccessNode = node;
        if (access.name_tok.value == "self" &&
            !init_complete(required, initialized)) {
            throw_missing_initializer(
                access.pos,
                "Cannot use 'self' before all fields of '" +
                class_name + "' are initialized."
            );
        }
        return InitFlow(initialized, false);
    }

    if (base.type == NODE_BINOP ||
        base.type == NODE_IS ||
        base.type == NODE_IS_NOT) {
        let binary: BinOpNode = node;
        check_init_node(
            c, class_name, binary.left, required, known_fields, initialized
        );
        check_init_node(
            c, class_name, binary.right, required, known_fields, initialized
        );
        return InitFlow(initialized, false);
    }

    if (base.type == NODE_UNARYOP) {
        let unary: UnaryOpNode = node;
        return check_init_node(
            c, class_name, unary.node, required, known_fields, initialized
        );
    }
    if (base.type == NODE_POSTFIX) {
        let postfix: PostfixOpNode = node;
        return check_init_node(
            c, class_name, postfix.node, required, known_fields, initialized
        );
    }
    if (base.type == NODE_REF) {
        let reference: RefNode = node;
        return check_init_node(
            c, class_name, reference.node, required, known_fields, initialized
        );
    }
    if (base.type == NODE_DEREF) {
        let dereference: DerefNode = node;
        return check_init_node(
            c, class_name, dereference.node, required, known_fields, initialized
        );
    }
    if (base.type == NODE_TRY_UNWRAP) {
        let unwrap: TryUnwrapNode = node;
        return check_init_node(
            c, class_name, unwrap.expr, required, known_fields, initialized
        );
    }

    if (base.type == NODE_VAR_DECL) {
        let declaration: VarDeclareNode = node;
        check_init_node(
            c, class_name, declaration.value, required, known_fields, initialized
        );
        return InitFlow(initialized, false);
    }
    if (base.type == NODE_VAR_ASSIGN) {
        let assignment: VarAssignNode = node;
        check_init_node(
            c, class_name, assignment.value, required, known_fields, initialized
        );
        return InitFlow(initialized, false);
    }
    if (base.type == NODE_PTR_ASSIGN) {
        let assignment: PtrAssignNode = node;
        check_init_node(
            c, class_name, assignment.pointer, required, known_fields, initialized
        );
        check_init_node(
            c, class_name, assignment.value, required, known_fields, initialized
        );
        return InitFlow(initialized, false);
    }
    if (base.type == NODE_INDEX_ACCESS) {
        let access: IndexAccessNode = node;
        check_init_node(
            c, class_name, access.target, required, known_fields, initialized
        );
        check_init_node(
            c, class_name, access.index_node, required, known_fields, initialized
        );
        return InitFlow(initialized, false);
    }
    if (base.type == NODE_INDEX_ASSIGN) {
        let assignment: IndexAssignNode = node;
        check_init_node(
            c, class_name, assignment.target, required, known_fields, initialized
        );
        check_init_node(
            c, class_name, assignment.index_node, required, known_fields, initialized
        );
        check_init_node(
            c, class_name, assignment.value, required, known_fields, initialized
        );
        return InitFlow(initialized, false);
    }
    if (base.type == NODE_SLICE_ACCESS) {
        let access: SliceAccessNode = node;
        check_init_node(
            c, class_name, access.target, required, known_fields, initialized
        );
        check_init_node(
            c, class_name, access.start_idx, required, known_fields, initialized
        );
        check_init_node(
            c, class_name, access.end_idx, required, known_fields, initialized
        );
        return InitFlow(initialized, false);
    }
    if (base.type == NODE_VECTOR_LIT) {
        let vector: VectorLitNode = node;
        let i: Int = 0;
        while (vector.elements is !null && i < vector.elements.length()) {
            let element: ArgNode = vector.elements[i];
            check_init_node(
                c, class_name, element.val, required, known_fields, initialized
            );
            i += 1;
        }
        return InitFlow(initialized, false);
    }
    if (base.type == NODE_MAP_LIT) {
        let map: MapLitNode = node;
        let i: Int = 0;
        while (map.pairs is !null && i < map.pairs.length()) {
            let pair: MapPairNode = map.pairs[i];
            check_init_node(
                c, class_name, pair.key, required, known_fields, initialized
            );
            check_init_node(
                c, class_name, pair.value, required, known_fields, initialized
            );
            i += 1;
        }
        return InitFlow(initialized, false);
    }
    if (base.type == NODE_SUPER &&
        init_has(required, "$super") &&
        !init_has(initialized, "$super")) {
        let super_node: SuperNode = node;
        throw_missing_initializer(
            super_node.pos,
            "Call super.init(...) before using the parent part of '" +
            class_name + "'."
        );
    }

    return InitFlow(initialized, false);
}

func check_class_initialization(c: Compiler, class_name: String, node: ClassDefNode, parent: StructInfo) -> Void {
    let required: Vector(String) = [];
    let known_fields: Vector(String) = [];
    let initialized: Vector(String) = [];

    let fields: Vector(Struct) = node.fields;
    let i: Int = 0;
    while (fields is !null && i < fields.length()) {
        let field: VarDeclareNode = fields[i];
        let name: String = field.name_tok.value;
        known_fields.append(name);
        if (field.value is null) {
            required.append(name);
        } else {
            initialized.append(name);
        }
        i += 1;
    }

    let parent_requires_init: Bool =
        class_requires_initialization(c, parent);
    if parent_requires_init {
        required.append("$super");
    } else {
        initialized.append("$super");
    }

    let default_required: Vector(String) = init_copy(known_fields);
    if parent_requires_init {
        default_required.append("$super");
    }

    let default_state: Vector(String) = [];
    if (!parent_requires_init) { default_state.append("$super"); }
    i = 0;
    while (fields is !null && i < fields.length()) {
        let field: VarDeclareNode = fields[i];
        if (field.value is !null) {
            check_init_node(
                c,
                class_name,
                field.value,
                default_required,
                known_fields,
                default_state
            );
            init_add(default_state, field.name_tok.value);
        }
        i += 1;
    }

    if (required.length() == 0) { return; }

    let initializer: MethodDefNode = null;
    let methods: Vector(Struct) = node.methods;
    i = 0;
    while (methods is !null && i < methods.length()) {
        let method_node: MethodDefNode = methods[i];
        if (method_node.name_tok.value == "$init") {
            initializer = method_node;
            break;
        }
        i += 1;
    }

    if (initializer is null) {
        let missing: String = required[0];
        if (missing == "$super") {
            throw_missing_initializer(
                node.pos,
                "Class '" + class_name +
                "' must define init and call super.init(...)."
            );
        } else {
            throw_missing_initializer(
                node.pos,
                "Field '" + missing + "' has no initializer, but class '" +
                class_name + "' does not define init."
            );
        }
        return;
    }

    let flow: InitFlow = check_init_node(
        c,
        class_name,
        initializer.body,
        required,
        known_fields,
        initialized
    );
    if (!flow.terminates) {
        init_require_complete(
            class_name,
            required,
            flow.initialized,
            initializer.pos
        );
    }
}

func emit_class_field_initializers(c: Compiler, class_info: StructInfo, object_reg: String, object_llvm_type: String) -> Void {
    if (class_info is null) { return; }

    if (class_info.parent_id != 0) {
        let parent: StructInfo =
            c.struct_id_map.lookup("" + class_info.parent_id);
        emit_class_field_initializers(
            c,
            parent,
            object_reg,
            object_llvm_type
        );
    }

    let initializer: FuncInfo =
        c.func_table.lookup(class_info.name + "_$field_init");
    if (initializer is null) { return; }
    queue_generic_class_method(c, class_info, "$field_init");

    let target_reg: String = object_reg;
    if (class_info.llvm_name != object_llvm_type) {
        target_reg = next_reg(c);
        c.output_file.write(
            c.indent + target_reg + " = bitcast " +
            object_llvm_type + "* " + object_reg + " to " +
            class_info.llvm_name + "*\n"
        );
    }
    c.output_file.write(
        c.indent + "call void @" + initializer.name + "(" +
        class_info.llvm_name + "* " + target_reg + ")\n"
    );
}


func must_terminate(c: Compiler, node: Struct) -> Bool {
    if (node is null) { return false; }
    let base: BaseNode = node;

    if (base.type == NODE_RETURN || base.type == NODE_BREAK ||
        base.type == NODE_CONTINUE || base.type == NODE_THROW) {
        return true;
    }

    if (base.type == NODE_BLOCK) {
        let block: BlockNode = node;
        if (block.stmts is null || block.stmts.length() == 0) { return false; }
        return must_terminate(c, block.stmts[block.stmts.length() - 1]);
    }

    if (base.type == NODE_IF) {
        let if_node: IfNode = node;
        let platform_value: Int = fold_target_cond(c, if_node.condition);
        if (platform_value == 1) {
            return must_terminate(c, if_node.body);
        }
        if (platform_value == 0 && if_node.else_body is !null) {
            return must_terminate(c, if_node.else_body);
        }

        // for a runtime condition, execution terminates only if both paths do
        if (platform_value == -1 && if_node.else_body is !null) {
            if (must_terminate(c, if_node.body) &&
                must_terminate(c, if_node.else_body)) {
                return true;
            }
        }
    }

    if (base.type == NODE_WHILE) {
        let loop: WhileNode = node;
        let condition: BaseNode = loop.condition;
        if (condition is !null && condition.type == NODE_BOOL) {
            let boolean: BooleanNode = loop.condition;
            return boolean.value == 1 && !has_loop_break(loop.body);
        }
    }
    if (base.type == NODE_FOR) {
        let loop: ForNode = node;
        if (loop.cond is null && !has_loop_break(loop.body)) { return true; }
        if (loop.cond is !null) {
            let condition: BaseNode = loop.cond;
            if (condition.type == NODE_BOOL) { let boolean: BooleanNode = loop.cond; if (boolean.value == 1 && !has_loop_break(loop.body)) { return true; } }
        }
    }
    return false;
}

func has_loop_break(node: Struct) -> Bool {
    if (node is null) { return false; }
    let base: BaseNode = node;
    if (base.type == NODE_BREAK) { return true; }
    if (base.type == NODE_WHILE || base.type == NODE_FOR) { return false; }
    if (base.type == NODE_BLOCK) {
        let block: BlockNode = node;
        let i: Int = 0;
        while (block.stmts is !null && i < block.stmts.length()) {
            if (has_loop_break(block.stmts[i])) { return true; }
            i += 1;
        }
        return false;
    }
    if (base.type == NODE_IF) {
        let branch: IfNode = node;
        return has_loop_break(branch.body) ||
               has_loop_break(branch.else_body);
    }
    if (base.type == NODE_CATCH) {
        let caught: CatchNode = node;
        return has_loop_break(caught.stmt) ||
               has_loop_break(caught.body);
    }
    return false;
}

