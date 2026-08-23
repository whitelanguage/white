// Test: WIR_LOOPS
// File: tests/integration/tooling/test_wir_loops.wl
// Focus: Lowering while loops and loop exits into explicit WIR control flow.

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

func loop_position() -> Position {
    return Position(idx=0, ln=1, col=1, text="", fn="memory.wl");
}

func loop_token(kind: Int, value: String) -> Token {
    return Token(type=kind, value=value, line=1, col=1);
}

func main() -> Int {
    let source: Compiler = Compiler(arena=new_ast_arena(), ptr_base_map=Dict());
    let pos: Position = loop_position();
    let condition: NodeID = add_var_access_node(source.arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=loop_token(TOK_IDENTIFIER, "flag"), pos=pos));
    let stop: NodeID = add_break_node(source.arena, BreakNode(type=NODE_BREAK, pos=pos));
    let loop_body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[stop]));
    let loop: NodeID = add_while_node(source.arena, WhileNode(type=NODE_WHILE, condition=condition, body=loop_body, pos=pos));
    let zero: NodeID = add_int_node(source.arena, IntNode(type=NODE_INT, tok=loop_token(TOK_INT, "0"), pos=pos));
    let return_zero: NodeID = add_return_node(source.arena, ReturnNode(type=NODE_RETURN, value=zero, pos=pos));
    let body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[loop, return_zero]));

    let args: Vector(Struct) = [TypeListNode(type=TYPE_BOOL, pass_mode=PARAM_VALUE)];
    let info: FuncInfo = FuncInfo(name="loop", base_name="loop", ret_type=TYPE_INT, arg_types=args, arg_names=["flag"], is_varargs=false, abi_name="");
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let types: WirTypeMap = new_wir_type_map();
    wir_lower_function_body(ref types, ref source, ref program, info, body);

    if (types.errors.length() != 0) {
        print("FAIL: valid loop was rejected: ", types.errors[0]);
        return 1;
    }
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: lowered loop produced invalid WIR: ", errors[0]);
        return 1;
    }

    let text: String = print_wir(program)?;
    catch(err) {
        print("FAIL: lowered loop could not be printed");
        return 1;
    }
    let expected: String = "internal func @loop(%flag:bool) -> i32 {\n^entry:\n    %flag.addr:ptr<bool> = alloca bool\n    store %flag, %flag.addr\n    jmp ^while.cond.0()\n\n^while.cond.0:\n    %3:bool = load %flag.addr\n    br %3, ^while.body.1(), ^while.end.2()\n\n^while.body.1:\n    jmp ^while.end.2()\n\n^while.end.2:\n    ret 0\n}\n";
    if (text != expected) {
        print("FAIL: lowered loop text is not stable");
        print(text);
        return 1;
    }

    print("PASS: WIR loops");
    return 0;
}
