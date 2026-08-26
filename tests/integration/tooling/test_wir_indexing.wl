// Test: WIR_INDEXING
// File: tests/integration/tooling/test_wir_indexing.wl
// Focus: Lowering checked String, Vector, slice, and pointer indexing to address operations.

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
import * from "../../../src/compiler/wir/lowering/functions.wl"

func indexing_position() -> Position {
    return Position(idx=0, ln=1, col=1, text="", fn="memory.wl");
}

func indexing_token(value: String) -> Token {
    return Token(type=TOK_IDENTIFIER, value=value, line=1, col=1);
}

func indexing_access(arena: AstArena, name: String, pos: Position) -> NodeID {
    return add_var_access_node(arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=indexing_token(name), pos=pos));
}

func indexing_body(arena: AstArena, target: String, pos: Position) -> NodeID {
    let access: NodeID = add_index_access_node(arena, IndexAccessNode(type=NODE_INDEX_ACCESS, target=indexing_access(arena, target, pos), index_node=indexing_access(arena, "index", pos), pos=pos));
    let result: NodeID = add_return_node(arena, ReturnNode(type=NODE_RETURN, value=access, pos=pos));
    return add_block_node(arena, BlockNode(type=NODE_BLOCK, stmts=[result]));
}

func indexing_length_body(arena: AstArena, target: String, pos: Position) -> NodeID {
    let member: NodeID = add_field_access_node(arena, FieldAccessNode(type=NODE_FIELD_ACCESS, obj=indexing_access(arena, target, pos), field_name="length", pos=pos));
    let call: NodeID = add_call_node(arena, CallNode(type=NODE_CALL, callee=member, args=[], type_args=[], pos=pos, preserve_fallible=false));
    let result: NodeID = add_return_node(arena, ReturnNode(type=NODE_RETURN, value=call, pos=pos));
    return add_block_node(arena, BlockNode(type=NODE_BLOCK, stmts=[result]));
}

func literal_length_body(arena: AstArena, pos: Position) -> NodeID {
    let literal: NodeID = add_string_node(arena, StringNode(type=NODE_STRING, tok=Token(type=TOK_STR_LIT, value="White", line=1, col=1), pos=pos));
    let member: NodeID = add_field_access_node(arena, FieldAccessNode(type=NODE_FIELD_ACCESS, obj=literal, field_name="length", pos=pos));
    let call: NodeID = add_call_node(arena, CallNode(type=NODE_CALL, callee=member, args=[], type_args=[], pos=pos, preserve_fallible=false));
    let result: NodeID = add_return_node(arena, ReturnNode(type=NODE_RETURN, value=call, pos=pos));
    return add_block_node(arena, BlockNode(type=NODE_BLOCK, stmts=[result]));
}

func indexing_info(name: String, target_type: Int, result_type: Int) -> FuncInfo {
    return FuncInfo(name=name, base_name=name, ret_type=result_type, arg_types=[TypeListNode(type=target_type, pass_mode=PARAM_VALUE), TypeListNode(type=TYPE_INT, pass_mode=PARAM_VALUE)], arg_names=["values", "index"], is_varargs=false, abi_name="");
}

func length_info(name: String, target_type: Int) -> FuncInfo {
    return FuncInfo(name=name, base_name=name, ret_type=TYPE_INT, arg_types=[TypeListNode(type=target_type, pass_mode=PARAM_VALUE)], arg_names=["values"], is_varargs=false, abi_name="");
}

func indexing_contains(text: String, needle: String) -> Bool {
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
    let vectors: Dict(String, SymbolInfo) = Dict();
    let arrays: Dict(String, ArrayInfo) = Dict();
    let pointers: Dict(String, SymbolInfo) = Dict();
    vectors.put("100", SymbolInfo(type=TYPE_INT));
    arrays.put("101", ArrayInfo(base_type=TYPE_INT, size=-1, llvm_name=""));
    pointers.put("102", SymbolInfo(type=TYPE_INT));
    let source: Compiler = Compiler(arena=new_ast_arena(), ptr_base_map=pointers, vector_base_map=vectors, array_info_map=arrays, struct_id_map=Dict());
    let pos: Position = indexing_position();
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let types: WirTypeMap = new_wir_type_map();

    wir_lower_function_body(ref types, ref source, ref program, indexing_info("string_at", TYPE_STRING, TYPE_BYTE), indexing_body(source.arena, "values", pos));
    if (types.errors.length() != 0) { print("FAIL: String indexing lowering: ", types.errors[0]); return 1; }
    wir_lower_function_body(ref types, ref source, ref program, indexing_info("vector_at", 100, TYPE_INT), indexing_body(source.arena, "values", pos));
    if (types.errors.length() != 0) { print("FAIL: Vector indexing lowering: ", types.errors[0]); return 1; }
    wir_lower_function_body(ref types, ref source, ref program, indexing_info("slice_at", 101, TYPE_INT), indexing_body(source.arena, "values", pos));
    if (types.errors.length() != 0) { print("FAIL: Slice indexing lowering: ", types.errors[0]); return 1; }
    wir_lower_function_body(ref types, ref source, ref program, indexing_info("pointer_at", 102, TYPE_INT), indexing_body(source.arena, "values", pos));
    if (types.errors.length() != 0) { print("FAIL: Pointer indexing lowering: ", types.errors[0]); return 1; }
    wir_lower_function_body(ref types, ref source, ref program, length_info("string_length", TYPE_STRING), indexing_length_body(source.arena, "values", pos));
    if (types.errors.length() != 0) { print("FAIL: String length lowering: ", types.errors[0]); return 1; }
    wir_lower_function_body(ref types, ref source, ref program, length_info("vector_length", 100), indexing_length_body(source.arena, "values", pos));
    if (types.errors.length() != 0) { print("FAIL: Vector length lowering: ", types.errors[0]); return 1; }
    wir_lower_function_body(ref types, ref source, ref program, length_info("slice_length", 101), indexing_length_body(source.arena, "values", pos));
    if (types.errors.length() != 0) { print("FAIL: Slice length lowering: ", types.errors[0]); return 1; }
    let literal_info: FuncInfo = FuncInfo(name="literal_length", base_name="literal_length", ret_type=TYPE_INT, arg_types=[], arg_names=[], is_varargs=false, abi_name="");
    wir_lower_function_body(ref types, ref source, ref program, literal_info, literal_length_body(source.arena, pos));
    if (types.errors.length() != 0) { print("FAIL: Temporary String length lowering: ", types.errors[0]); return 1; }

    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: WIR indexing verification: ", errors[0]);
        return 1;
    }
    let text: String = print_wir(program)?;
    catch(err) { print("FAIL: WIR indexing could not be printed"); return 1; }
    if (!indexing_contains(text, "func @string_at") || !indexing_contains(text, "func @vector_at") ||
        !indexing_contains(text, "func @slice_at") || !indexing_contains(text, "func @pointer_at") ||
        !indexing_contains(text, "func @string_length") || !indexing_contains(text, "func @vector_length") || !indexing_contains(text, "func @slice_length") || !indexing_contains(text, "func @literal_length") ||
        !indexing_contains(text, "check.bounds") || !indexing_contains(text, "index.addr")) {
        print("FAIL: WIR indexing operations are incomplete");
        return 1;
    }
    print("PASS: WIR indexing");
    return 0;
}
