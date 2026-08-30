// Test: WIR_GLOBALS
// File: tests/integration/tooling/test_wir_globals.wl
// Focus: Lowering scalar globals and resolving global reads and writes in function bodies.

import * from "../../../src/compiler/context.wl"
import * from "../../../src/frontend/ast.wl"
import * from "../../../src/frontend/arena.wl"
import * from "../../../src/frontend/tokens.wl"
import Position from "../../../src/frontend/diagnostics.wl"
import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/verify.wl"
import * from "../../../src/compiler/wir/print.wl"
import * from "../../../src/compiler/wir/lowering/types.wl"
import * from "../../../src/compiler/wir/lowering/globals.wl"
import * from "../../../src/compiler/wir/lowering/functions.wl"

func global_position() -> Position {
    return Position(idx=0, ln=1, col=1, text="", fn="memory.wl");
}

func global_token(kind: Int, value: String) -> Token {
    return Token(type=kind, value=value, line=1, col=1);
}

func global_access(arena: AstArena, name: String, pos: Position) -> NodeID {
    return add_var_access_node(arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=global_token(TOK_IDENTIFIER, name), pos=pos));
}

func global_int(arena: AstArena, value: String, pos: Position) -> NodeID {
    return add_int_node(arena, IntNode(type=NODE_INT, tok=global_token(TOK_INT, value), pos=pos));
}

func global_decl(arena: AstArena, name: String, type_name: String, value: NodeID, is_const: Bool, pos: Position) -> VarDeclareNode {
    return VarDeclareNode(type=NODE_VAR_DECL, name_tok=global_token(TOK_IDENTIFIER, name), type_node=global_access(arena, type_name, pos), value=value, is_const=is_const, annotations=[], pos=pos, alloc_id=0);
}

func global_contains(text: String, needle: String) -> Bool {
    let start: Int = 0;
    while (start + needle.length() <= text.length()) {
        let offset: Int = 0;
        while (offset < needle.length() && text[start + offset] == needle[offset]) { offset++; }
        if (offset == needle.length()) { return true; }
        start++;
    }
    return needle.length() == 0;
}

func check_null_global() -> Bool {
    let symbols: Dict(String, SymbolInfo) = Dict();
    symbols.put("buffer", SymbolInfo(reg="poison", type=TYPE_STRING, origin_type=TYPE_STRING, is_const=false));
    let source: Compiler = Compiler(arena=new_ast_arena(), symbol_table=Scope(table=Dict(), parent=-1, gc_vars=[], depth=0), scope_stack=[], global_symbol_table=symbols, current_package_prefix="", current_file_global_aliases=Dict(), global_var_aliases=Dict(), generic_bindings=Dict());
    let pos: Position = global_position();
    let value: NodeID = add_null_node(source.arena, NullNode(type=NODE_NULL, pos=pos));
    let declaration: VarDeclareNode = global_decl(source.arena, "buffer", "String", value, false, pos);
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let types: WirTypeMap = new_wir_type_map();
    wir_lower_global_decl(ref types, ref source, ref program, declaration);
    if (types.errors.length() != 0) { return false; }
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) { return false; }
    let text: String = print_wir(program)?;
    catch(err) { return false; }
    return global_contains(text, "@buffer") && global_contains(text, " = null");
}

func main() -> Int {
    if (!check_null_global()) {
        print("FAIL: null String global");
        return 1;
    }
    let symbols: Dict(String, SymbolInfo) = Dict();
    let aliases: Dict(String, String) = Dict();
    let imported_aliases: Dict(String, String) = Dict();
    let named_types: Dict(String, NamedTypeInfo) = Dict();
    let generics: Dict(String, SymbolInfo) = Dict();
    let locals: Dict(String, SymbolInfo) = Dict();
    symbols.put("counter", SymbolInfo(reg="poison", type=TYPE_INT, origin_type=TYPE_INT, is_const=false));
    symbols.put("limit", SymbolInfo(reg="poison", type=TYPE_INT, origin_type=TYPE_INT, is_const=true));
    symbols.put("ready", SymbolInfo(reg="poison", type=TYPE_BOOL, origin_type=TYPE_BOOL, is_const=true));
    symbols.put("mask", SymbolInfo(reg="poison", type=TYPE_UINT32, origin_type=TYPE_UINT32, is_const=true));
    let source: Compiler = Compiler(arena=new_ast_arena(), symbol_table=Scope(table=locals, parent=-1, gc_vars=[], depth=0), scope_stack=[], global_symbol_table=symbols, current_package_prefix="", current_file_global_aliases=aliases, global_var_aliases=imported_aliases, named_type_ids=named_types, generic_bindings=generics);
    let pos: Position = global_position();
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let types: WirTypeMap = new_wir_type_map();

    let counter: VarDeclareNode = global_decl(source.arena, "counter", "Int", global_int(source.arena, "1", pos), false, pos);
    let negative: NodeID = add_unary_node(source.arena, UnaryOpNode(type=NODE_UNARYOP, op_tok=global_token(TOK_SUB, "-"), node=global_int(source.arena, "2", pos), pos=pos));
    let limit: VarDeclareNode = global_decl(source.arena, "limit", "Int", negative, true, pos);
    let ready_value: NodeID = add_bool_node(source.arena, BooleanNode(type=NODE_BOOL, tok=global_token(TOK_TRUE, "true"), value=1, pos=pos));
    let ready: VarDeclareNode = global_decl(source.arena, "ready", "Bool", ready_value, true, pos);
    let mask: VarDeclareNode = global_decl(source.arena, "mask", "UInt32", global_int(source.arena, "0x00ff_ffffU", pos), true, pos);
    wir_lower_global_decl(ref types, ref source, ref program, counter);
    wir_lower_global_decl(ref types, ref source, ref program, limit);
    wir_lower_global_decl(ref types, ref source, ref program, ready);
    wir_lower_global_decl(ref types, ref source, ref program, mask);

    let assignment: NodeID = add_var_assign_node(source.arena, VarAssignNode(type=NODE_VAR_ASSIGN, name_tok=global_token(TOK_IDENTIFIER, "counter"), value=global_int(source.arena, "7", pos), pos=pos));
    let return_value: NodeID = add_return_node(source.arena, ReturnNode(type=NODE_RETURN, value=global_access(source.arena, "counter", pos), pos=pos));
    let body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[assignment, return_value]));
    let info: FuncInfo = FuncInfo(name="use_global", base_name="use_global", ret_type=TYPE_INT, arg_types=[], arg_names=[], is_varargs=false, abi_name="");
    wir_lower_function_body(ref types, ref source, ref program, info, body);

    if (types.errors.length() != 0) {
        print("FAIL: valid globals were rejected: ", types.errors[0]);
        return 1;
    }
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: globals produced invalid WIR: ", errors[0]);
        return 1;
    }

    let text: String = print_wir(program)?;
    catch(err) {
        print("FAIL: global WIR could not be printed");
        return 1;
    }
    let expected: String = "internal global @counter:i32 = 1\ninternal const @limit:i32 = -2\ninternal const @ready:bool = true\ninternal const @mask:u32 = 16777215\n\ninternal func @use_global() -> i32 {\n^entry:\n    store 7, @counter\n    %10:i32 = load @counter\n    ret %10\n}\n";
    if (text != expected) {
        print("FAIL: lowered global text is not stable");
        print(text);
        return 1;
    }
    print("PASS: WIR global lowering");
    return 0;
}
