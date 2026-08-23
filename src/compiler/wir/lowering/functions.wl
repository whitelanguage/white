// compiler/wir/lowering/functions.wl
import * from "../model.wl"
import * from "../builder.wl"
import * from "types.wl"
import * from "declarations.wl"
import * from "../../context.wl"
import parse_const_uint128, parse_decimal_float_literal from "../../constants.wl"
import * from "../../../frontend/ast.wl"
import * from "../../../frontend/arena.wl"
import * from "../../../frontend/tokens.wl"

struct WirBinding(
    name: String,
    source_type: Int,
    address: WirValueID,
    is_const: Bool
)

struct WirExpr(
    value: WirValueID,
    source_type: Int
)

struct WirLoop(
    continue_block: WirBlockID,
    break_block: WirBlockID
)

struct WirFunctionLowering(
    function: WirFuncID,
    block: WirBlockID,
    bindings: Vector(WirBinding),
    loops: Vector(WirLoop),
    errors: Vector(String),
    terminated: Bool,
    next_block: Int
)

func wir_no_expr() -> WirExpr {
    return WirExpr(value=NO_WIR_VALUE, source_type=TYPE_POISON);
}

func wir_find_binding(state: WirFunctionLowering, name: String) -> WirBinding? {
    let i: Int = state.bindings.length() - 1;
    while (i >= 0) {
        if (state.bindings[i].name == name) { return state.bindings[i]; }
        i--;
    }
    throw Error.InvalidData;
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
    if (kind == NODE_VAR_ACCESS) {
        let access: VarAccessNode = get_var_access_node(source.arena, node);
        let binding: WirBinding = wir_find_binding(state, access.name_tok.value)?;
        catch(err) {
            state.errors.append("unknown local '" + access.name_tok.value + "' in WIR lowering");
            return wir_no_expr();
        }
        let value: WirValueID = wir_load(ref program, state.block, binding.address, "", no_wir_location());
        return WirExpr(value=value, source_type=binding.source_type);
    }
    if (kind == NODE_BINOP) {
        let binary: BinOpNode = get_binop_node(source.arena, node);
        let left: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, binary.left);
        let right: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, binary.right);
        if (left.value == NO_WIR_VALUE || right.value == NO_WIR_VALUE) { return wir_no_expr(); }
        if (left.source_type != right.source_type) {
            state.errors.append("binary operands reached WIR lowering with different source types");
            return wir_no_expr();
        }

        let opcode: WirOpcode = wir_numeric_opcode(left.source_type, binary.op_tok.type);
        if (opcode == WirOpcode.Invalid) {
            state.errors.append("binary operator '" + binary.op_tok.value + "' is not lowered to WIR yet");
            return wir_no_expr();
        }
        let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, left.source_type);
        let value: WirValueID = wir_binary(ref program, state.block, opcode, type_id, left.value, right.value, "", no_wir_location());
        return WirExpr(value=value, source_type=left.source_type);
    }
    if (kind == NODE_CALL) {
        let call: CallNode = get_call_node(source.arena, node);
        if (node_tag(call.callee) != NODE_VAR_ACCESS) {
            state.errors.append("indirect calls are not lowered to WIR yet");
            return wir_no_expr();
        }
        if (call.preserve_fallible) {
            state.errors.append("fallible calls are not lowered to WIR yet");
            return wir_no_expr();
        }

        let callee: VarAccessNode = get_var_access_node(source.arena, call.callee);
        let info: FuncInfo = source.func_table.lookup(callee.name_tok.value);
        if (!has_func(info) && source.current_package_prefix.length() != 0) { info = source.func_table.lookup(source.current_package_prefix + callee.name_tok.value); }
        if (!has_func(info)) {
            state.errors.append("unknown function '" + callee.name_tok.value + "' in WIR lowering");
            return wir_no_expr();
        }

        let function_id: WirFuncID = wir_find_function(program, info.name);
        if (function_id == NO_WIR_FUNC) { function_id = wir_lower_function_decl(ref types, ref source, ref program, info); }
        if (function_id == NO_WIR_FUNC) { return wir_no_expr(); }
        let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
        let signature: WirType = program.arena.types[wir_id_index(UInt32(function.type_id))];
        let arguments: Vector(WirValueID) = [];
        let i: Int = 0;
        while (i < call.args.length()) {
            let argument: ArgNode = call.args[i];
            if (argument.name.length() != 0 || argument.is_spread) {
                state.errors.append("named and spread arguments must be bound before WIR lowering");
                return wir_no_expr();
            }
            let value: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, argument.val);
            if (value.value == NO_WIR_VALUE) { return wir_no_expr(); }
            if (i < signature.parameters.length() && wir_value_type(program, value.value) != signature.parameters[i]) {
                state.errors.append("argument " + i + " to '" + info.name + "' requires a conversion before WIR lowering");
                return wir_no_expr();
            }
            arguments.append(value.value);
            i++;
        }
        let result: WirValueID = wir_call(ref program, state.block, function.address, arguments, "", no_wir_location());
        return WirExpr(value=result, source_type=info.ret_type);
    }

    state.errors.append("AST node kind " + kind + " is not lowered to WIR yet");
    return wir_no_expr();
}

func wir_lower_var(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: VarDeclareNode) -> Void {
    let value: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, node.value);
    if (value.value == NO_WIR_VALUE) { return; }

    let source_type: Int = value.source_type;
    if (has_node(node.type_node)) {
        let declared: Int = resolve_type(ref source, node.type_node);
        if (declared != TYPE_AUTO) { source_type = declared; }
    }
    if (source_type != value.source_type) {
        state.errors.append("local '" + node.name_tok.value + "' requires a conversion before WIR lowering");
        return;
    }

    let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
    let address: WirValueID = wir_stack_alloc(ref program, state.block, type_id, node.name_tok.value + ".addr", no_wir_location());
    wir_store(ref program, state.block, value.value, address, no_wir_location());
    state.bindings.append(WirBinding(name=node.name_tok.value, source_type=source_type, address=address, is_const=node.is_const));
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
            state.errors.append("unknown local '" + statement.name_tok.value + "' in WIR lowering");
            return;
        }
        if (binding.is_const) {
            state.errors.append("const local '" + statement.name_tok.value + "' reached WIR lowering with an assignment");
            return;
        }
        let value: WirExpr = wir_lower_expr(ref state, ref types, ref source, ref program, statement.value);
        if (value.value == NO_WIR_VALUE) { return; }
        if (value.source_type != binding.source_type) {
            state.errors.append("assignment to '" + statement.name_tok.value + "' requires a conversion before WIR lowering");
            return;
        }
        wir_store(ref program, state.block, value.value, binding.address, no_wir_location());
        return;
    }
    if (kind == NODE_RETURN) {
        let statement: ReturnNode = get_return_node(source.arena, node);
        let function: WirFunction = program.arena.functions[wir_id_index(UInt32(state.function))];
        let signature: WirType = program.arena.types[wir_id_index(UInt32(function.type_id))];
        let result: WirExpr = wir_no_expr();
        if (has_node(statement.value)) { result = wir_lower_expr(ref state, ref types, ref source, ref program, statement.value); }
        if (signature.result == program.void_type) {
            if (result.value != NO_WIR_VALUE) { state.errors.append("Void function reached WIR lowering with a return value"); return; }
        } else if (result.value == NO_WIR_VALUE) {
            state.errors.append("non-Void function reached WIR lowering without a return value");
            return;
        } else if (wir_value_type(program, result.value) != signature.result) {
            state.errors.append("return value reached WIR lowering with the wrong type");
            return;
        }
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

        state.loops.append(WirLoop(continue_block=condition_block, break_block=end_block));
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
        wir_lower_stmt(ref state, ref types, ref source, ref program, block.stmts[i]);
        i++;
    }
    wir_restore_bindings(ref state, binding_count);
}

func wir_lower_function_body(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, info: FuncInfo, body: NodeID) -> WirFuncID {
    let function_id: WirFuncID = wir_lower_function_decl(ref types, ref source, ref program, info);
    if (function_id == NO_WIR_FUNC) { return NO_WIR_FUNC; }
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    if (function.linkage == WirLinkage.External) {
        types.errors.append("external function '" + info.name + "' has a body");
        return function_id;
    }

    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let state: WirFunctionLowering = WirFunctionLowering(function=function_id, block=entry, bindings=[], loops=[], errors=[], terminated=false, next_block=0);
    let i: Int = 0;
    while (i < function.parameters.length()) {
        let parameter: WirValueID = function.parameters[i];
        let source_parameter: TypeListNode = info.arg_types[i];
        let name: String = program.arena.values[wir_id_index(UInt32(parameter))].name;
        if (source_parameter.pass_mode == PARAM_REF) {
            state.bindings.append(WirBinding(name=name, source_type=source_parameter.type, address=parameter, is_const=false));
        } else {
            let source_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_parameter.type);
            let address: WirValueID = wir_stack_alloc(ref program, entry, source_type, name + ".addr", no_wir_location());
            wir_store(ref program, entry, parameter, address, no_wir_location());
            state.bindings.append(WirBinding(name=name, source_type=source_parameter.type, address=address, is_const=false));
        }
        i++;
    }

    wir_lower_block(ref state, ref types, ref source, ref program, body);
    let signature: WirType = program.arena.types[wir_id_index(UInt32(function.type_id))];
    if (!state.terminated) {
        if (signature.result == program.void_type) {
            wir_return(ref program, entry, NO_WIR_VALUE, no_wir_location());
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
