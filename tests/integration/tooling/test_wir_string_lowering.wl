// Test: WIR_STRING_LOWERING
// File: tests/integration/tooling/test_wir_string_lowering.wl
// Focus: Lowering shared String literals to static WIR data and relocatable addresses.

import * from "../../../src/compiler/context.wl"
import * from "../../../src/frontend/ast.wl"
import * from "../../../src/frontend/arena.wl"
import * from "../../../src/frontend/tokens.wl"
import Position from "../../../src/frontend/diagnostics.wl"
import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/verify.wl"
import * from "../../../src/compiler/wir/print.wl"
import * from "../../../src/compiler/wir/backend/llvm.wl"
import * from "../../../src/compiler/wir/lowering/module.wl"
import * from "../../../src/compiler/wir/lowering/types.wl"
import * from "../../../src/compiler/wir/lowering/functions.wl"

func string_position() -> Position {
    return Position(idx=0, ln=1, col=1, text="", fn="memory.wl");
}

func string_token(kind: Int, value: String) -> Token {
    return Token(type=kind, value=value, line=1, col=1);
}

func string_access(arena: AstArena, name: String, pos: Position) -> NodeID {
    return add_var_access_node(arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=string_token(TOK_IDENTIFIER, name), pos=pos));
}

func string_literal(arena: AstArena, value: String, pos: Position) -> NodeID {
    return add_string_node(arena, StringNode(type=NODE_STRING, tok=string_token(TOK_STR_LIT, value), pos=pos));
}

func check_string_concat() -> Bool {
    let functions: Dict(String, FuncInfo) = Dict();
    let links: Dict(String, String) = Dict();
    let args: Vector(Struct) = [TypeListNode(type=TYPE_STRING, pass_mode=PARAM_VALUE), TypeListNode(type=TYPE_STRING, pass_mode=PARAM_VALUE)];
    functions.put("runtime.concat", FuncInfo(name="runtime.concat", base_name="string_concat", ret_type=TYPE_STRING, arg_types=args, arg_names=["left", "right"], is_varargs=false, abi_name="C"));
    links.put("string_concat", "runtime.concat");
    let source: Compiler = Compiler(arena=new_ast_arena(), ptr_base_map=Dict(), struct_id_map=Dict(), func_table=functions, compiler_link=links);
    let pos: Position = string_position();
    let left: NodeID = string_access(source.arena, "left", pos);
    let right: NodeID = string_access(source.arena, "right", pos);
    let sum: NodeID = add_binop_node(source.arena, BinOpNode(type=NODE_BINOP, left=left, op_tok=string_token(TOK_PLUS, "+"), right=right, pos=pos));
    let result: NodeID = add_return_node(source.arena, ReturnNode(type=NODE_RETURN, value=sum, pos=pos));
    let body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[result]));
    let info: FuncInfo = FuncInfo(name="join", base_name="join", ret_type=TYPE_STRING, arg_types=args, arg_names=["left", "right"], is_varargs=false, abi_name="");
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let types: WirTypeMap = new_wir_type_map();
    wir_lower_function_body(ref types, ref source, ref program, info, body);
    let errors: Vector(String) = verify_wir(program);
    if (types.errors.length() != 0) { print("FAIL: String concatenation lowering: ", types.errors[0]); return false; }
    if (errors.length() != 0) { print("FAIL: String concatenation verification: ", errors[0]); return false; }
    let text: String = print_wir(program)?;
    catch(err) { return false; }
    if (!string_contains(text, "call @runtime.concat")) { print(text); return false; }
    return true;
}

func string_contains(text: String, needle: String) -> Bool {
    let start: Int = 0;
    while (start + needle.length() <= text.length()) {
        let offset: Int = 0;
        while (offset < needle.length() && text[start + offset] == needle[offset]) { offset++; }
        if (offset == needle.length()) { return true; }
        start++;
    }
    return needle.length() == 0;
}

func main() -> Int {
    let symbols: Dict(String, SymbolInfo) = Dict();
    let functions: Dict(String, FuncInfo) = Dict();
    let aliases: Dict(String, String) = Dict();
    let named_types: Dict(String, NamedTypeInfo) = Dict();
    let generics: Dict(String, SymbolInfo) = Dict();
    let locals: Dict(String, SymbolInfo) = Dict();
    symbols.put("message", SymbolInfo(reg="poison", type=TYPE_STRING, origin_type=TYPE_STRING, is_const=true));
    functions.put("message_text", FuncInfo(name="message_text", base_name="message_text", ret_type=TYPE_STRING, arg_types=[], arg_names=[], is_varargs=false, abi_name=""));
    let source: Compiler = Compiler(arena=new_ast_arena(), symbol_table=Scope(table=locals, parent=-1, gc_vars=[], depth=0), scope_stack=[], global_symbol_table=symbols, func_table=functions, current_package_prefix="", current_file_global_aliases=aliases, global_var_aliases=aliases, named_type_ids=named_types, generic_bindings=generics);
    let pos: Position = string_position();

    let literal: NodeID = string_literal(source.arena, "White", pos);
    let global: NodeID = add_var_decl_node(source.arena, VarDeclareNode(type=NODE_VAR_DECL, name_tok=string_token(TOK_IDENTIFIER, "message"), type_node=string_access(source.arena, "String", pos), value=literal, is_const=true, annotations=[], pos=pos, alloc_id=0));
    let returned: NodeID = add_return_node(source.arena, ReturnNode(type=NODE_RETURN, value=string_literal(source.arena, "White", pos), pos=pos));
    let body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[returned]));
    let function: NodeID = add_func_def_node(source.arena, FunctionDefNode(type=NODE_FUNC_DEF, name_tok=string_token(TOK_IDENTIFIER, "message_text"), type_params=[], params=[], ret_type_tok=string_access(source.arena, "String", pos), body=body, annotations=[], pos=pos));
    let root: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[global, function]));

    let result: WirLoweringResult = wir_lower_module(ref source, root, "x86_64-pc-windows-msvc", 64);
    if (result.errors.length() != 0) { print("FAIL: String literal lowering failed: ", result.errors[0]); return 1; }
    if (result.program.arena.constants.length() != 5 || result.program.arena.globals.length() != 3) {
        print("FAIL: identical String literals were not deduplicated");
        return 1;
    }

    let text: String = print_wir(result.program)?;
    catch(err) { print("FAIL: String WIR could not be printed"); return 1; }
    let expected: String = "type !$String = {ptr<u8>, i32, i32}\n\ntype !t10 = {i32, i32, !$String}\n\nconst @.str.0.bytes:[u8; 6] align 1 = b\"White\\00\"\nconst @.str.0:!t10 align 8 = {-1, 5, {addr @.str.0.bytes, 5, 5}}\ninternal const @message:ptr<!$String> = addr @.str.0 + 8\n\ninternal func @message_text() -> ptr<!$String> {\n^entry:\n    retain addr @.str.0 + 8\n    ret addr @.str.0 + 8\n}\n";
    if (text != expected) { print("FAIL: lowered String WIR is not stable"); print(text); return 1; }

    let emitted: WirLLVMResult = emit_wir_llvm(result.program)?;
    catch(err) { print("FAIL: String LLVM emission failed"); return 1; }
    if (emitted.errors.length() != 0) { print("FAIL: String WIR was rejected: ", emitted.errors[0]); return 1; }
    if (!check_string_concat()) { print("FAIL: String concatenation lowering"); return 1; }
    print("PASS: WIR String literal lowering");
    return 0;
}
