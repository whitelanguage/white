// Test: WIR_FALLIBLE
// File: tests/integration/tooling/test_wir_fallible.wl
// Focus: Lowering fallible propagation and local catch recovery to primitive WIR control flow.

import * from "../../../src/compiler/context.wl"
import * from "../../../src/frontend/ast.wl"
import * from "../../../src/frontend/arena.wl"
import * from "../../../src/frontend/tokens.wl"
import Position from "../../../src/frontend/diagnostics.wl"
import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/verify.wl"
import * from "../../../src/compiler/wir/print.wl"
import WirLLVMResult, emit_wir_llvm from "../../../src/compiler/wir/backend/llvm.wl"
import * from "../../../src/compiler/wir/lowering/types.wl"
import * from "../../../src/compiler/wir/lowering/functions.wl"

func fallible_position() -> Position {
    return Position(idx=0, ln=1, col=1, text="", fn="memory.wl");
}

func fallible_token(kind: Int, value: String) -> Token {
    return Token(type=kind, value=value, line=1, col=1);
}

func fallible_access(arena: AstArena, name: String, pos: Position) -> NodeID {
    return add_var_access_node(arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=fallible_token(TOK_IDENTIFIER, name), pos=pos));
}

func fallible_integer(arena: AstArena, value: String, pos: Position) -> NodeID {
    return add_int_node(arena, IntNode(type=NODE_INT, tok=fallible_token(TOK_INT, value), pos=pos));
}

func fallible_call(arena: AstArena, name: String, pos: Position) -> NodeID {
    let call: NodeID = add_call_node(arena, CallNode(type=NODE_CALL, callee=fallible_access(arena, name, pos), args=[], type_args=[], pos=pos, preserve_fallible=true));
    return add_try_unwrap_node(arena, TryUnwrapNode(type=NODE_TRY_UNWRAP, expr=call, pos=pos));
}

func fallible_source(arena: AstArena) -> Compiler {
    return Compiler(arena=arena, ptr_base_map=Dict(), fallible_cache=Dict(), fallible_base_map=Dict(), func_table=Dict(), func_ret_map=Dict(), method_ret_map=Dict(), generic_type_names=Dict(), struct_id_map=Dict(), current_package_prefix="", type_counter=100);
}

func fallible_contains(text: String, needle: String) -> Bool {
    let start: Int = 0;
    while (start + needle.length() <= text.length()) {
        let offset: Int = 0;
        while (offset < needle.length() && text[start + offset] == needle[offset]) { offset++; }
        if (offset == needle.length()) { return true; }
        start++;
    }
    return needle.length() == 0;
}

func fallible_emits_llvm(program: WirModule) -> Bool {
    let emitted: WirLLVMResult = emit_wir_llvm(program)?;
    catch(err) { return false; }
    return emitted.errors.length() == 0 && emitted.text.length() != 0;
}

func check_propagation() -> Bool {
    let arena: AstArena = new_ast_arena();
    let source: Compiler = fallible_source(arena);
    let fallible_string: Int = get_fallible_type_id(ref source, TYPE_STRING);
    source.func_table.put("read", FuncInfo(name="read", base_name="read", ret_type=fallible_string, arg_types=[], arg_names=[], is_varargs=false, abi_name="C"));
    let pos: Position = fallible_position();
    let result: NodeID = add_return_node(arena, ReturnNode(type=NODE_RETURN, value=fallible_call(arena, "read", pos), pos=pos));
    let body: NodeID = add_block_node(arena, BlockNode(type=NODE_BLOCK, stmts=[result]));
    let info: FuncInfo = FuncInfo(name="forward", base_name="forward", ret_type=fallible_string, arg_types=[], arg_names=[], is_varargs=false, abi_name="");
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let types: WirTypeMap = new_wir_type_map();
    wir_lower_function_body(ref types, ref source, ref program, info, body);
    if (types.errors.length() != 0) { return false; }
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) { return false; }
    let text: String = print_wir(program)?;
    catch(err) { return false; }
    return fallible_contains(text, "br ") && fallible_contains(text, "field") && fallible_contains(text, "struct") && fallible_contains(text, "ret") && fallible_emits_llvm(program);
}

func check_catch() -> Bool {
    let arena: AstArena = new_ast_arena();
    let source: Compiler = fallible_source(arena);
    let fallible_void: Int = get_fallible_type_id(ref source, TYPE_VOID);
    source.func_table.put("flush", FuncInfo(name="flush", base_name="flush", ret_type=fallible_void, arg_types=[], arg_names=[], is_varargs=false, abi_name="C"));
    let pos: Position = fallible_position();
    let caught_return: NodeID = add_return_node(arena, ReturnNode(type=NODE_RETURN, value=fallible_integer(arena, "7", pos), pos=pos));
    let catch_body: NodeID = add_block_node(arena, BlockNode(type=NODE_BLOCK, stmts=[caught_return]));
    let caught: NodeID = add_catch_node(arena, CatchNode(type=NODE_CATCH, stmt=fallible_call(arena, "flush", pos), err_name=fallible_token(TOK_IDENTIFIER, "err"), body=catch_body, pos=pos, alloc_id=0));
    let normal_return: NodeID = add_return_node(arena, ReturnNode(type=NODE_RETURN, value=fallible_integer(arena, "0", pos), pos=pos));
    let body: NodeID = add_block_node(arena, BlockNode(type=NODE_BLOCK, stmts=[caught, normal_return]));
    let info: FuncInfo = FuncInfo(name="recover", base_name="recover", ret_type=TYPE_INT, arg_types=[], arg_names=[], is_varargs=false, abi_name="");
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let types: WirTypeMap = new_wir_type_map();
    wir_lower_function_body(ref types, ref source, ref program, info, body);
    if (types.errors.length() != 0) { return false; }
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) { return false; }
    let text: String = print_wir(program)?;
    catch(err) { return false; }
    return fallible_contains(text, "^catch.") && fallible_contains(text, "^catch.end.") && fallible_contains(text, "ret 7") && fallible_contains(text, "ret 0") && fallible_emits_llvm(program);
}

func check_throw() -> Bool {
    let arena: AstArena = new_ast_arena();
    let source: Compiler = fallible_source(arena);
    let error_type: Int = 150;
    let fields: Vector(Struct) = [FieldInfo(name="Failure", type=error_type, llvm_type="i32", offset=1)];
    source.struct_id_map.put("" + error_type, StructInfo(name="ProbeError", type_id=error_type, fields=fields, is_enum=true, is_error=true));
    let fallible_int: Int = get_fallible_type_id(ref source, TYPE_INT);
    let pos: Position = fallible_position();
    let owner: NodeID = fallible_access(arena, "ProbeError", pos);
    let member: NodeID = add_field_access_node(arena, FieldAccessNode(type=NODE_FIELD_ACCESS, obj=owner, field_name="Failure", pos=pos));
    let statement: NodeID = add_throw_node(arena, ThrowNode(type=NODE_THROW, value=member, pos=pos));
    let body: NodeID = add_block_node(arena, BlockNode(type=NODE_BLOCK, stmts=[statement]));
    let info: FuncInfo = FuncInfo(name="fail", base_name="fail", ret_type=fallible_int, arg_types=[], arg_names=[], is_varargs=false, abi_name="");
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let types: WirTypeMap = new_wir_type_map();
    types.enum_values.put("ProbeError.Failure", WirEnumValue(value=1, source_type=error_type));
    wir_lower_function_body(ref types, ref source, ref program, info, body);
    if (types.errors.length() != 0) { return false; }
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) { return false; }
    let text: String = print_wir(program)?;
    catch(err) { return false; }
    return fallible_contains(text, "struct") && fallible_contains(text, "ret") && fallible_emits_llvm(program);
}

func main() -> Int {
    if (!check_propagation()) {
        print("FAIL: WIR fallible propagation");
        return 1;
    }
    if (!check_catch()) {
        print("FAIL: WIR catch recovery");
        return 1;
    }
    if (!check_throw()) {
        print("FAIL: WIR throw propagation");
        return 1;
    }
    print("PASS: WIR fallible control flow");
    return 0;
}
