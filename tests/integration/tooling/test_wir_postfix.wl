// Test: WIR_POSTFIX
// File: tests/integration/tooling/test_wir_postfix.wl
// Focus: Keeping the old value while updating postfix increment and decrement targets.

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

func postfix_position() -> Position {
    return Position(idx=0, ln=1, col=1, text="", fn="memory.wl");
}

func postfix_token(kind: Int, value: String) -> Token {
    return Token(type=kind, value=value, line=1, col=1);
}

func postfix_access(arena: AstArena, pos: Position) -> NodeID {
    return add_var_access_node(arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=postfix_token(TOK_IDENTIFIER, "value"), pos=pos));
}

func check_postfix_expression() -> Bool {
    let source: Compiler = Compiler(arena=new_ast_arena(), ptr_base_map=Dict());
    let pos: Position = postfix_position();
    let postfix: NodeID = add_postfix_node(source.arena, PostfixOpNode(type=NODE_POSTFIX, node=postfix_access(source.arena, pos), op_tok=postfix_token(TOK_INC, "++"), pos=pos));
    let result: NodeID = add_return_node(source.arena, ReturnNode(type=NODE_RETURN, value=postfix, pos=pos));
    let body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[result]));
    let args: Vector(Struct) = [TypeListNode(type=TYPE_INT, pass_mode=PARAM_VALUE)];
    let info: FuncInfo = FuncInfo(name="post_inc", base_name="post_inc", ret_type=TYPE_INT, arg_types=args, arg_names=["value"], is_varargs=false, abi_name="");
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let types: WirTypeMap = new_wir_type_map();
    wir_lower_function_body(ref types, ref source, ref program, info, body);
    if (types.errors.length() != 0) { return false; }
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) { return false; }
    let text: String = print_wir(program)?;
    catch(err) { return false; }
    return text == "internal func @post_inc(%value:i32) -> i32 {\n^entry:\n    %value.addr:ptr<i32> = alloca i32\n    store %value, %value.addr\n    %3:i32 = load %value.addr\n    %5:i32 = add %3, 1\n    store %5, %value.addr\n    ret %3\n}\n";
}

func check_postfix_statement() -> Bool {
    let source: Compiler = Compiler(arena=new_ast_arena(), ptr_base_map=Dict());
    let pos: Position = postfix_position();
    let postfix: NodeID = add_postfix_node(source.arena, PostfixOpNode(type=NODE_POSTFIX, node=postfix_access(source.arena, pos), op_tok=postfix_token(TOK_DEC, "--"), pos=pos));
    let result: NodeID = add_return_node(source.arena, ReturnNode(type=NODE_RETURN, value=postfix_access(source.arena, pos), pos=pos));
    let body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[postfix, result]));
    let args: Vector(Struct) = [TypeListNode(type=TYPE_FLOAT, pass_mode=PARAM_VALUE)];
    let info: FuncInfo = FuncInfo(name="post_dec", base_name="post_dec", ret_type=TYPE_FLOAT, arg_types=args, arg_names=["value"], is_varargs=false, abi_name="");
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let types: WirTypeMap = new_wir_type_map();
    wir_lower_function_body(ref types, ref source, ref program, info, body);
    if (types.errors.length() != 0) { return false; }
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) { return false; }
    let text: String = print_wir(program)?;
    catch(err) { return false; }
    return text == "internal func @post_dec(%value:f64) -> f64 {\n^entry:\n    %value.addr:ptr<f64> = alloca f64\n    store %value, %value.addr\n    %3:f64 = load %value.addr\n    %5:f64 = sub %3, f64(0x3FF0000000000000)\n    store %5, %value.addr\n    %6:f64 = load %value.addr\n    ret %6\n}\n";
}

func main() -> Int {
    if (!check_postfix_expression()) { print("FAIL: WIR postfix expression"); return 1; }
    if (!check_postfix_statement()) { print("FAIL: WIR postfix statement"); return 1; }
    print("PASS: WIR postfix expressions");
    return 0;
}
