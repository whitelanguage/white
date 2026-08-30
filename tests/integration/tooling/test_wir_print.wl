// Test: WIR_PRINT
// File: tests/integration/tooling/test_wir_print.wl
// Focus: Lowering print arguments to runtime calls without keeping print in WIR.

import * from "../../../src/compiler/context.wl"
import * from "../../../src/frontend/ast.wl"
import * from "../../../src/frontend/arena.wl"
import * from "../../../src/frontend/tokens.wl"
import Position from "../../../src/frontend/diagnostics.wl"
import * from "../../../src/compiler/wir/print.wl"
import * from "../../../src/compiler/wir/lowering/module.wl"
import WirLLVMResult, emit_wir_llvm from "../../../src/compiler/wir/backend/llvm.wl"

func print_position() -> Position {
    return Position(idx=0, ln=1, col=1, text="", fn="memory.wl");
}

func print_token(kind: Int, value: String) -> Token {
    return Token(type=kind, value=value, line=1, col=1);
}

func print_access(arena: AstArena, name: String, pos: Position) -> NodeID {
    return add_var_access_node(arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=print_token(TOK_IDENTIFIER, name), pos=pos));
}

func print_string(arena: AstArena, value: String, pos: Position) -> NodeID {
    return add_string_node(arena, StringNode(type=NODE_STRING, tok=print_token(TOK_STR_LIT, value), pos=pos));
}

func print_contains(text: String, needle: String) -> Bool {
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
    let arena: AstArena = new_ast_arena();
    let functions: Dict(String, FuncInfo) = Dict();
    let links: Dict(String, String) = Dict();
    let bytes_args: Vector(Struct) = [TypeListNode(type=TYPE_ANYPTR, pass_mode=PARAM_VALUE), TypeListNode(type=TYPE_INT, pass_mode=PARAM_VALUE)];
    let int_args: Vector(Struct) = [TypeListNode(type=TYPE_INT, pass_mode=PARAM_VALUE)];
    functions.put("main", FuncInfo(name="main", base_name="main", ret_type=TYPE_INT, arg_types=[], arg_names=[], is_varargs=false, abi_name=""));
    functions.put("print", FuncInfo(name="print", base_name="print", ret_type=TYPE_VOID, arg_types=[], arg_names=[], is_varargs=true, abi_name="", ann_flags=FLAG_ANN_INTRINSIC));
    functions.put("runtime.write_bytes", FuncInfo(name="runtime.write_bytes", base_name="write_bytes", ret_type=TYPE_VOID, arg_types=bytes_args, arg_names=["data", "length"], is_varargs=false, abi_name="C"));
    functions.put("runtime.write_int", FuncInfo(name="runtime.write_int", base_name="write_int", ret_type=TYPE_VOID, arg_types=int_args, arg_names=["value"], is_varargs=false, abi_name="C"));
    links.put("print_bytes", "runtime.write_bytes");
    links.put("print_int", "runtime.write_int");

    let symbols: Dict(String, SymbolInfo) = Dict();
    let aliases: Dict(String, String) = Dict();
    let source: Compiler = Compiler(arena=arena, symbol_table=Scope(table=Dict(), parent=-1, gc_vars=[], depth=0), scope_stack=[], global_symbol_table=symbols, func_table=functions, compiler_link=links, current_package_prefix="", current_file_global_aliases=aliases, global_var_aliases=aliases, named_type_ids=Dict(), generic_bindings=Dict());
    let pos: Position = print_position();
    let arguments: Vector(ArgNode) = [
        ArgNode(name="", val=print_string(arena, "value", pos), is_spread=false),
        ArgNode(name="", val=add_int_node(arena, IntNode(type=NODE_INT, tok=print_token(TOK_INT, "7"), pos=pos)), is_spread=false),
        ArgNode(name="sep", val=print_string(arena, "|", pos), is_spread=false),
        ArgNode(name="end", val=print_string(arena, "!", pos), is_spread=false)
    ];
    let call: NodeID = add_call_node(arena, CallNode(type=NODE_CALL, callee=print_access(arena, "print", pos), args=arguments, type_args=[], pos=pos, preserve_fallible=false));
    let zero: NodeID = add_int_node(arena, IntNode(type=NODE_INT, tok=print_token(TOK_INT, "0"), pos=pos));
    let returned: NodeID = add_return_node(arena, ReturnNode(type=NODE_RETURN, value=zero, pos=pos));
    let body: NodeID = add_block_node(arena, BlockNode(type=NODE_BLOCK, stmts=[call, returned]));
    let function: NodeID = add_func_def_node(arena, FunctionDefNode(type=NODE_FUNC_DEF, name_tok=print_token(TOK_IDENTIFIER, "main"), type_params=[], params=[], ret_type_tok=print_access(arena, "Int", pos), body=body, annotations=[], pos=pos));
    let root: NodeID = add_block_node(arena, BlockNode(type=NODE_BLOCK, stmts=[function]));

    let result: WirLoweringResult = wir_lower_module(ref source, root, "x86_64-pc-windows-msvc", 64);
    if (result.errors.length() != 0) { print("FAIL: print lowering failed: ", result.errors[0]); return 1; }
    let text: String = print_wir(result.program)?;
    catch(err) { print("FAIL: print WIR could not be rendered"); return 1; }
    if (!print_contains(text, "call @runtime.write_bytes") || !print_contains(text, "call @runtime.write_int(7)")) {
        print("FAIL: print did not lower to runtime calls");
        return 1;
    }
    let emitted: WirLLVMResult = emit_wir_llvm(result.program)?;
    catch(err) { print("FAIL: print LLVM emission failed"); return 1; }
    if (emitted.errors.length() != 0 || !print_contains(emitted.text, "call ccc void @runtime.write_bytes") || !print_contains(emitted.text, "call ccc void @runtime.write_int(i32 7)")) {
        print("FAIL: print runtime calls were lost in LLVM emission");
        return 1;
    }
    print("PASS: WIR print lowering");
    return 0;
}
