// Test: WIR_FUNCTION_VALUES
// File: tests/integration/tooling/test_wir_function_values.wl
// Focus: Lowering function values stored in locals and called indirectly.

import * from "../../../src/compiler/context.wl"
import * from "../../../src/frontend/ast.wl"
import * from "../../../src/frontend/arena.wl"
import * from "../../../src/frontend/tokens.wl"
import Position from "../../../src/frontend/diagnostics.wl"
import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/lowering/module.wl"

func function_value_position() -> Position {
    return Position(idx=0, ln=1, col=1, text="", fn="memory.wl");
}

func function_value_token(kind: Int, value: String) -> Token {
    return Token(type=kind, value=value, line=1, col=1);
}

func function_value_access(arena: AstArena, name: String, pos: Position) -> NodeID {
    return add_var_access_node(arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=function_value_token(TOK_IDENTIFIER, name), pos=pos));
}

func function_value_int(arena: AstArena, value: String, pos: Position) -> NodeID {
    return add_int_node(arena, IntNode(type=NODE_INT, tok=function_value_token(TOK_INT, value), pos=pos));
}

func function_value_call(arena: AstArena, name: String, args: Vector(ArgNode), pos: Position) -> NodeID {
    return add_call_node(arena, CallNode(type=NODE_CALL, callee=function_value_access(arena, name, pos), args=args, type_args=[], pos=pos, preserve_fallible=false));
}

func function_value_return(arena: AstArena, value: NodeID, pos: Position) -> NodeID {
    return add_return_node(arena, ReturnNode(type=NODE_RETURN, value=value, pos=pos));
}

func function_value_definition(arena: AstArena, name: String, body: NodeID, pos: Position) -> NodeID {
    return add_func_def_node(arena, FunctionDefNode(type=NODE_FUNC_DEF, name_tok=function_value_token(TOK_IDENTIFIER, name), type_params=[], params=[], ret_type_tok=function_value_access(arena, "Int", pos), body=body, annotations=[], pos=pos));
}

func main() -> Int {
    let aliases: Dict(String, String) = Dict();
    let links: Dict(String, String) = Dict();
    links.put("memory_alloc", "memory_alloc");
    links.put("memory_free", "memory_free");
    let source: Compiler = Compiler(arena=new_ast_arena(), symbol_table=Scope(table=Dict(), parent=-1, gc_vars=[], depth=0), scope_stack=[], global_symbol_table=Dict(), func_table=Dict(), compiler_link=links, current_package_prefix="", current_file_global_aliases=aliases, global_var_aliases=aliases, named_type_ids=Dict(), generic_bindings=Dict(), ptr_base_map=Dict(), ptr_cache=Dict(), func_ret_map=Dict(), method_ret_map=Dict(), type_counter=200);
    let pos: Position = function_value_position();
    let int_args: Vector(Struct) = [TypeListNode(type=TYPE_INT, pass_mode=PARAM_VALUE), TypeListNode(type=TYPE_INT, pass_mode=PARAM_VALUE)];
    let function_type: Int = get_func_type_id(ref source, int_args, TYPE_INT, 0, ["", ""]);

    let add_info: FuncInfo = FuncInfo(name="add", base_name="add", ret_type=TYPE_INT, arg_types=int_args, arg_names=["a", "b"], is_varargs=false, abi_name="");
    let apply_info: FuncInfo = FuncInfo(name="apply", base_name="apply", ret_type=TYPE_INT, arg_types=[TypeListNode(type=function_type, pass_mode=PARAM_VALUE)], arg_names=["f"], is_varargs=false, abi_name="");
    let main_info: FuncInfo = FuncInfo(name="main", base_name="main", ret_type=TYPE_INT, arg_types=[], arg_names=[], is_varargs=false, abi_name="");
    source.func_table.put("add", add_info);
    source.func_table.put("apply", apply_info);
    source.func_table.put("main", main_info);
    source.func_table.put("memory_alloc", FuncInfo(name="memory_alloc", base_name="memory_alloc", ret_type=TYPE_ANYPTR, arg_types=[TypeListNode(type=TYPE_UINTSIZE, pass_mode=PARAM_VALUE)], arg_names=["size"], is_varargs=false, abi_name="C"));
    source.func_table.put("memory_free", FuncInfo(name="memory_free", base_name="memory_free", ret_type=TYPE_VOID, arg_types=[TypeListNode(type=TYPE_ANYPTR, pass_mode=PARAM_VALUE)], arg_names=["block"], is_varargs=false, abi_name="C"));

    let add_sum: NodeID = add_binop_node(source.arena, BinOpNode(type=NODE_BINOP, left=function_value_access(source.arena, "a", pos), op_tok=function_value_token(TOK_PLUS, "+"), right=function_value_access(source.arena, "b", pos), pos=pos));
    let add_body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[function_value_return(source.arena, add_sum, pos)]));

    let indirect_args: Vector(ArgNode) = [ArgNode(val=function_value_int(source.arena, "2", pos), name="", is_spread=false), ArgNode(val=function_value_int(source.arena, "3", pos), name="", is_spread=false)];
    let indirect_call: NodeID = function_value_call(source.arena, "f", indirect_args, pos);
    let apply_body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[function_value_return(source.arena, indirect_call, pos)]));

    let chosen: NodeID = add_var_decl_node(source.arena, VarDeclareNode(type=NODE_VAR_DECL, name_tok=function_value_token(TOK_IDENTIFIER, "chosen"), type_node=NO_NODE, value=function_value_access(source.arena, "add", pos), is_const=false, annotations=[], pos=pos, alloc_id=0));
    let apply_args: Vector(ArgNode) = [ArgNode(val=function_value_access(source.arena, "chosen", pos), name="", is_spread=false)];
    let apply_call: NodeID = function_value_call(source.arena, "apply", apply_args, pos);
    let main_body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[chosen, function_value_return(source.arena, apply_call, pos)]));

    let root: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[function_value_definition(source.arena, "add", add_body, pos), function_value_definition(source.arena, "apply", apply_body, pos), function_value_definition(source.arena, "main", main_body, pos)]));
    let result: WirLoweringResult = wir_lower_module(ref source, root, "x86_64-pc-windows-msvc", 64);
    if (result.errors.length() != 0) {
        print("FAIL: function values were rejected: ", result.errors[0]);
        return 1;
    }

    let allocation_calls: Int = 0;
    let indirect_calls: Int = 0;
    let saw_retain: Bool = false;
    let saw_release: Bool = false;
    let i: Int = 0;
    while (i < result.program.arena.instructions.length()) {
        let instruction: WirInstruction = result.program.arena.instructions[i];
        if (instruction.opcode == WirOpcode.Retain) { saw_retain = true; }
        if (instruction.opcode == WirOpcode.Release) { saw_release = true; }
        if (instruction.opcode == WirOpcode.Call) {
            let callee: WirValue = result.program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
            if (callee.kind == WirValueKind.Function && callee.name == "memory_alloc") { allocation_calls++; }
            if (callee.kind == WirValueKind.Instruction && instruction.call_type != NO_WIR_TYPE) { indirect_calls++; }
        }
        i++;
    }
    if (allocation_calls == 0 || indirect_calls < 2 || !saw_retain || !saw_release) {
        print("FAIL: callable lowering alloc=", allocation_calls, " indirect=", indirect_calls, " retain=", saw_retain, " release=", saw_release);
        return 1;
    }
    print("PASS: WIR function values");
    return 0;
}
