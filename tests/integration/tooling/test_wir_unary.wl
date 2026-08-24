// Test: WIR_UNARY
// File: tests/integration/tooling/test_wir_unary.wl
// Focus: Preserving integer, floating-point, logical and bitwise unary operations in WIR.

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

func unary_position() -> Position {
    return Position(idx=0, ln=1, col=1, text="", fn="memory.wl");
}

func unary_token(kind: Int, value: String) -> Token {
    return Token(type=kind, value=value, line=1, col=1);
}

func check_unary(source_type: Int, token_kind: Int, token_value: String, wir_type: String, opcode: String) -> Bool {
    let source: Compiler = Compiler(arena=new_ast_arena(), ptr_base_map=Dict());
    let pos: Position = unary_position();
    let access: NodeID = add_var_access_node(source.arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=unary_token(TOK_IDENTIFIER, "value"), pos=pos));
    let unary: NodeID = add_unary_node(source.arena, UnaryOpNode(type=NODE_UNARYOP, op_tok=unary_token(token_kind, token_value), node=access, pos=pos));
    let result: NodeID = add_return_node(source.arena, ReturnNode(type=NODE_RETURN, value=unary, pos=pos));
    let body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[result]));

    let args: Vector(Struct) = [TypeListNode(type=source_type, pass_mode=PARAM_VALUE)];
    let info: FuncInfo = FuncInfo(name="unary", base_name="unary", ret_type=source_type, arg_types=args, arg_names=["value"], is_varargs=false, abi_name="");
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let types: WirTypeMap = new_wir_type_map();
    wir_lower_function_body(ref types, ref source, ref program, info, body);
    if (types.errors.length() != 0) { return false; }
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) { return false; }

    let text: String = print_wir(program)?;
    catch(err) { return false; }
    let expected: String = "internal func @unary(%value:" + wir_type + ") -> " + wir_type + " {\n^entry:\n    %value.addr:ptr<" + wir_type + "> = alloca " + wir_type + "\n    store %value, %value.addr\n    %3:" + wir_type + " = load %value.addr\n    %4:" + wir_type + " = " + opcode + " %3\n    ret %4\n}\n";
    return text == expected;
}

func check_unary_plus() -> Bool {
    let source: Compiler = Compiler(arena=new_ast_arena(), ptr_base_map=Dict());
    let pos: Position = unary_position();
    let access: NodeID = add_var_access_node(source.arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=unary_token(TOK_IDENTIFIER, "value"), pos=pos));
    let unary: NodeID = add_unary_node(source.arena, UnaryOpNode(type=NODE_UNARYOP, op_tok=unary_token(TOK_PLUS, "+"), node=access, pos=pos));
    let result: NodeID = add_return_node(source.arena, ReturnNode(type=NODE_RETURN, value=unary, pos=pos));
    let body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[result]));
    let args: Vector(Struct) = [TypeListNode(type=TYPE_INT, pass_mode=PARAM_VALUE)];
    let info: FuncInfo = FuncInfo(name="positive", base_name="positive", ret_type=TYPE_INT, arg_types=args, arg_names=["value"], is_varargs=false, abi_name="");
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let types: WirTypeMap = new_wir_type_map();
    wir_lower_function_body(ref types, ref source, ref program, info, body);
    if (types.errors.length() != 0) { return false; }
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) { return false; }
    let text: String = print_wir(program)?;
    catch(err) { return false; }
    return text == "internal func @positive(%value:i32) -> i32 {\n^entry:\n    %value.addr:ptr<i32> = alloca i32\n    store %value, %value.addr\n    %3:i32 = load %value.addr\n    ret %3\n}\n";
}

func main() -> Int {
    if (!check_unary(TYPE_INT, TOK_SUB, "-", "i32", "neg")) { print("FAIL: WIR integer negation"); return 1; }
    if (!check_unary(TYPE_FLOAT, TOK_SUB, "-", "f64", "fneg")) { print("FAIL: WIR floating-point negation"); return 1; }
    if (!check_unary(TYPE_BOOL, TOK_NOT, "!", "bool", "not")) { print("FAIL: WIR logical not"); return 1; }
    if (!check_unary(TYPE_UINT32, TOK_BIT_NOT, "~", "u32", "not")) { print("FAIL: WIR bitwise not"); return 1; }
    if (!check_unary_plus()) { print("FAIL: WIR unary plus"); return 1; }
    print("PASS: WIR unary expressions");
    return 0;
}
