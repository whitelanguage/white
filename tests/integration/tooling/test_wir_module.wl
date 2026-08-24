// Test: WIR_MODULE
// File: tests/integration/tooling/test_wir_module.wl
// Focus: Lowering a registered root AST with globals and forward function calls.

import * from "../../../src/compiler/context.wl"
import * from "../../../src/frontend/ast.wl"
import * from "../../../src/frontend/arena.wl"
import * from "../../../src/frontend/tokens.wl"
import Position from "../../../src/frontend/diagnostics.wl"
import * from "../../../src/compiler/wir/print.wl"
import * from "../../../src/compiler/wir/lowering/module.wl"

func module_position() -> Position {
    return Position(idx=0, ln=1, col=1, text="", fn="memory.wl");
}

func module_token(kind: Int, value: String) -> Token {
    return Token(type=kind, value=value, line=1, col=1);
}

func module_access(arena: AstArena, name: String, pos: Position) -> NodeID {
    return add_var_access_node(arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=module_token(TOK_IDENTIFIER, name), pos=pos));
}

func module_return(arena: AstArena, value: NodeID, pos: Position) -> NodeID {
    return add_return_node(arena, ReturnNode(type=NODE_RETURN, value=value, pos=pos));
}

func module_function(arena: AstArena, name: String, body: NodeID, pos: Position) -> NodeID {
    let return_type: NodeID = module_access(arena, "Int", pos);
    return add_func_def_node(arena, FunctionDefNode(type=NODE_FUNC_DEF, name_tok=module_token(TOK_IDENTIFIER, name), type_params=[], params=[], ret_type_tok=return_type, body=body, annotations=[], pos=pos));
}

func main() -> Int {
    let symbols: Dict(String, SymbolInfo) = Dict();
    let functions: Dict(String, FuncInfo) = Dict();
    let aliases: Dict(String, String) = Dict();
    let named_types: Dict(String, NamedTypeInfo) = Dict();
    let generics: Dict(String, SymbolInfo) = Dict();
    let locals: Dict(String, SymbolInfo) = Dict();
    symbols.put("counter", SymbolInfo(reg="poison", type=TYPE_INT, origin_type=TYPE_INT, is_const=false));
    let main_info: FuncInfo = FuncInfo(name="main", base_name="main", ret_type=TYPE_INT, arg_types=[], arg_names=[], is_varargs=false, abi_name="");
    let helper_info: FuncInfo = FuncInfo(name="helper", base_name="helper", ret_type=TYPE_INT, arg_types=[], arg_names=[], is_varargs=false, abi_name="");
    functions.put("main", main_info);
    functions.put("helper", helper_info);
    let source: Compiler = Compiler(arena=new_ast_arena(), symbol_table=Scope(table=locals, parent=-1, gc_vars=[], depth=0), scope_stack=[], global_symbol_table=symbols, func_table=functions, current_package_prefix="", current_file_global_aliases=aliases, global_var_aliases=aliases, named_type_ids=named_types, generic_bindings=generics);
    let pos: Position = module_position();

    let global_type: NodeID = module_access(source.arena, "Int", pos);
    let global_value: NodeID = add_int_node(source.arena, IntNode(type=NODE_INT, tok=module_token(TOK_INT, "3"), pos=pos));
    let global: NodeID = add_var_decl_node(source.arena, VarDeclareNode(type=NODE_VAR_DECL, name_tok=module_token(TOK_IDENTIFIER, "counter"), type_node=global_type, value=global_value, is_const=false, annotations=[], pos=pos, alloc_id=0));

    let helper_callee: NodeID = module_access(source.arena, "helper", pos);
    let helper_call: NodeID = add_call_node(source.arena, CallNode(type=NODE_CALL, callee=helper_callee, args=[], type_args=[], pos=pos, preserve_fallible=false));
    let main_body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[module_return(source.arena, helper_call, pos)]));
    let main_node: NodeID = module_function(source.arena, "main", main_body, pos);
    let helper_body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[module_return(source.arena, module_access(source.arena, "counter", pos), pos)]));
    let helper_node: NodeID = module_function(source.arena, "helper", helper_body, pos);
    let root: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[global, main_node, helper_node]));

    let result: WirLoweringResult = wir_lower_module(ref source, root, "x86_64-pc-windows-msvc", 64);
    if (result.errors.length() != 0) {
        print("FAIL: valid root module was rejected: ", result.errors[0]);
        return 1;
    }
    let text: String = print_wir(result.program)?;
    catch(err) {
        print("FAIL: lowered root module could not be printed");
        return 1;
    }
    let expected: String = "internal global @counter:i32 = 3\n\nexport func @main() -> i32 {\n^entry:\n    %4:i32 = call @helper()\n    ret %4\n}\n\ninternal func @helper() -> i32 {\n^entry:\n    %5:i32 = load @counter\n    ret %5\n}\n";
    if (text != expected) {
        print("FAIL: lowered root module text is not stable");
        print(text);
        return 1;
    }
    print("PASS: WIR module lowering");
    return 0;
}
