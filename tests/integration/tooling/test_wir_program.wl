// Test: WIR_PROGRAM
// File: tests/integration/tooling/test_wir_program.wl
// Focus: Declaring every module before lowering cross-module calls.

import * from "../../../src/compiler/context.wl"
import * from "../../../src/frontend/ast.wl"
import * from "../../../src/frontend/arena.wl"
import * from "../../../src/frontend/tokens.wl"
import Position from "../../../src/frontend/diagnostics.wl"
import * from "../../../src/compiler/wir/print.wl"
import * from "../../../src/compiler/wir/lowering/module.wl"

func program_position() -> Position {
    return Position(idx=0, ln=1, col=1, text="", fn="memory.wl");
}

func program_token(kind: Int, value: String) -> Token {
    return Token(type=kind, value=value, line=1, col=1);
}

func program_access(arena: AstArena, name: String, pos: Position) -> NodeID {
    return add_var_access_node(arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=program_token(TOK_IDENTIFIER, name), pos=pos));
}

func program_function(arena: AstArena, name: String, value: NodeID, pos: Position) -> NodeID {
    let return_node: NodeID = add_return_node(arena, ReturnNode(type=NODE_RETURN, value=value, pos=pos));
    let body: NodeID = add_block_node(arena, BlockNode(type=NODE_BLOCK, stmts=[return_node]));
    let return_type: NodeID = program_access(arena, "Int", pos);
    return add_func_def_node(arena, FunctionDefNode(type=NODE_FUNC_DEF, name_tok=program_token(TOK_IDENTIFIER, name), type_params=[], params=[], ret_type_tok=return_type, body=body, annotations=[], pos=pos));
}

func empty_visible() -> Dict(String, String) {
    return Dict();
}

func empty_namespaces() -> Dict(String, Bool) {
    return Dict();
}

func program_contains(text: String, needle: String) -> Bool {
    if (needle.length() == 0) { return true; }
    let start: Int = 0;
    while (start + needle.length() <= text.length()) {
        let offset: Int = 0;
        while (offset < needle.length() && text[start + offset] == needle[offset]) { offset++; }
        if (offset == needle.length()) { return true; }
        start++;
    }
    return false;
}

func main() -> Int {
    let arena: AstArena = new_ast_arena();
    let functions: Dict(String, FuncInfo) = Dict();
    functions.put("main", FuncInfo(name="main", base_name="main", ret_type=TYPE_INT, arg_types=[], arg_names=[], is_varargs=false, abi_name=""));
    functions.put("lib.answer", FuncInfo(name="lib.answer", base_name="answer", ret_type=TYPE_INT, arg_types=[], arg_names=[], is_varargs=false, abi_name=""));

    let aliases: Dict(String, String) = Dict();
    aliases.put("answer", "lib.answer");
    let source: Compiler = Compiler(arena=arena, symbol_table=Scope(table=Dict(), parent=-1, gc_vars=[], depth=0), scope_stack=[], global_symbol_table=Dict(), func_table=functions, current_package_prefix="", current_file_global_aliases=Dict(), global_var_aliases=Dict(), named_type_ids=Dict(), generic_bindings=Dict());
    let pos: Position = program_position();

    let answer_value: NodeID = add_int_node(arena, IntNode(type=NODE_INT, tok=program_token(TOK_INT, "42"), pos=pos));
    let answer_root: NodeID = add_block_node(arena, BlockNode(type=NODE_BLOCK, stmts=[program_function(arena, "answer", answer_value, pos)]));

    let callee: NodeID = program_access(arena, "answer", pos);
    let call: NodeID = add_call_node(arena, CallNode(type=NODE_CALL, callee=callee, args=[], type_args=[], pos=pos, preserve_fallible=false));
    let main_root: NodeID = add_block_node(arena, BlockNode(type=NODE_BLOCK, stmts=[program_function(arena, "main", call, pos)]));

    let modules: Vector(ParsedModule) = [
        ParsedModule(path="lib.wl", prefix="lib.", dir="", is_package=false, ast=answer_root, visible=empty_visible(), namespaces=empty_namespaces(), types=Dict(), funcs=Dict(), globals=Dict(), imports=[]),
        ParsedModule(path="main.wl", prefix="", dir="", is_package=false, ast=main_root, visible=empty_visible(), namespaces=empty_namespaces(), types=Dict(), funcs=aliases, globals=Dict(), imports=[])
    ];
    let result: WirLoweringResult = wir_lower_program(ref source, modules, "x86_64-pc-windows-msvc", 64);
    if (result.errors.length() != 0) {
        print("FAIL: valid multi-module program was rejected: ", result.errors[0]);
        return 1;
    }

    let text: String = print_wir(result.program)?;
    catch(err) {
        print("FAIL: multi-module WIR could not be printed");
        return 1;
    }
    if (!program_contains(text, "call @lib.answer()")) {
        print("FAIL: imported function did not resolve to its module symbol");
        return 1;
    }
    print("PASS: WIR program lowering");
    return 0;
}
