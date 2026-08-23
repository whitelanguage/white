// Test: WIR_CONTROL_FLOW
// File: tests/integration/tooling/test_wir_control.wl
// Focus: Lowering Bool conditions and early returns into explicit WIR blocks.

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

func control_position() -> Position {
    return Position(idx=0, ln=1, col=1, text="", fn="memory.wl");
}

func control_token(value: String) -> Token {
    return Token(type=TOK_IDENTIFIER, value=value, line=1, col=1);
}

func control_access(arena: AstArena, name: String, pos: Position) -> NodeID {
    return add_var_access_node(arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=control_token(name), pos=pos));
}

func main() -> Int {
    let source: Compiler = Compiler(arena=new_ast_arena(), ptr_base_map=Dict());
    let pos: Position = control_position();
    let return_a: NodeID = add_return_node(source.arena, ReturnNode(type=NODE_RETURN, value=control_access(source.arena, "a", pos), pos=pos));
    let then_body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[return_a]));
    let choose_a: NodeID = add_if_node(source.arena, IfNode(type=NODE_IF, condition=control_access(source.arena, "flag", pos), body=then_body, else_body=NO_NODE, pos=pos));
    let return_b: NodeID = add_return_node(source.arena, ReturnNode(type=NODE_RETURN, value=control_access(source.arena, "b", pos), pos=pos));
    let body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[choose_a, return_b]));

    let args: Vector(Struct) = [TypeListNode(type=TYPE_BOOL, pass_mode=PARAM_VALUE), TypeListNode(type=TYPE_INT, pass_mode=PARAM_VALUE), TypeListNode(type=TYPE_INT, pass_mode=PARAM_VALUE)];
    let info: FuncInfo = FuncInfo(name="select", base_name="select", ret_type=TYPE_INT, arg_types=args, arg_names=["flag", "a", "b"], is_varargs=false, abi_name="");
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let types: WirTypeMap = new_wir_type_map();
    wir_lower_function_body(ref types, ref source, ref program, info, body);

    if (types.errors.length() != 0) {
        print("FAIL: valid control flow was rejected: ", types.errors[0]);
        return 1;
    }
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: lowered control flow produced invalid WIR: ", errors[0]);
        return 1;
    }

    let text: String = print_wir(program)?;
    catch(err) {
        print("FAIL: lowered control flow could not be printed");
        return 1;
    }
    let expected: String = "internal func @select(%flag:bool, %a:i32, %b:i32) -> i32 {\n^entry:\n    %flag.addr:ptr<bool> = alloca bool\n    store %flag, %flag.addr\n    %a.addr:ptr<i32> = alloca i32\n    store %a, %a.addr\n    %b.addr:ptr<i32> = alloca i32\n    store %b, %b.addr\n    %7:bool = load %flag.addr\n    br %7, ^if.then.0(), ^if.end.1()\n\n^if.then.0:\n    %8:i32 = load %a.addr\n    ret %8\n\n^if.end.1:\n    %9:i32 = load %b.addr\n    ret %9\n}\n";
    if (text != expected) {
        print("FAIL: lowered control-flow text is not stable");
        print(text);
        return 1;
    }

    print("PASS: WIR control flow");
    return 0;
}
