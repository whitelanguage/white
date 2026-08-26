// Test: WIR_SHORT_CIRCUIT
// File: tests/integration/tooling/test_wir_logic.wl
// Focus: Lowering logical operators without eagerly evaluating the right operand.

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

func logic_position() -> Position {
    return Position(idx=0, ln=1, col=1, text="", fn="memory.wl");
}

func logic_token(kind: Int, value: String) -> Token {
    return Token(type=kind, value=value, line=1, col=1);
}

func check_nested_logic() -> Bool {
    let source: Compiler = Compiler(arena=new_ast_arena(), ptr_base_map=Dict());
    let pos: Position = logic_position();
    let a: NodeID = add_var_access_node(source.arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=logic_token(TOK_IDENTIFIER, "a"), pos=pos));
    let b: NodeID = add_var_access_node(source.arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=logic_token(TOK_IDENTIFIER, "b"), pos=pos));
    let c: NodeID = add_var_access_node(source.arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=logic_token(TOK_IDENTIFIER, "c"), pos=pos));
    let either: NodeID = add_binop_node(source.arena, BinOpNode(type=NODE_BINOP, left=b, op_tok=logic_token(TOK_OR, "||"), right=c, pos=pos));
    let expression: NodeID = add_binop_node(source.arena, BinOpNode(type=NODE_BINOP, left=a, op_tok=logic_token(TOK_AND, "&&"), right=either, pos=pos));
    let result: NodeID = add_return_node(source.arena, ReturnNode(type=NODE_RETURN, value=expression, pos=pos));
    let body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[result]));
    let args: Vector(Struct) = [TypeListNode(type=TYPE_BOOL, pass_mode=PARAM_VALUE), TypeListNode(type=TYPE_BOOL, pass_mode=PARAM_VALUE), TypeListNode(type=TYPE_BOOL, pass_mode=PARAM_VALUE)];
    let info: FuncInfo = FuncInfo(name="nested", base_name="nested", ret_type=TYPE_BOOL, arg_types=args, arg_names=["a", "b", "c"], is_varargs=false, abi_name="");
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let types: WirTypeMap = new_wir_type_map();
    wir_lower_function_body(ref types, ref source, ref program, info, body);
    let errors: Vector(String) = verify_wir(program);
    return types.errors.length() == 0 && errors.length() == 0;
}

func main() -> Int {
    let source: Compiler = Compiler(arena=new_ast_arena(), ptr_base_map=Dict());
    let pos: Position = logic_position();
    let left: NodeID = add_var_access_node(source.arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=logic_token(TOK_IDENTIFIER, "a"), pos=pos));
    let right: NodeID = add_var_access_node(source.arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=logic_token(TOK_IDENTIFIER, "b"), pos=pos));
    let both: NodeID = add_binop_node(source.arena, BinOpNode(type=NODE_BINOP, left=left, op_tok=logic_token(TOK_AND, "&&"), right=right, pos=pos));
    let result: NodeID = add_return_node(source.arena, ReturnNode(type=NODE_RETURN, value=both, pos=pos));
    let body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[result]));

    let args: Vector(Struct) = [TypeListNode(type=TYPE_BOOL, pass_mode=PARAM_VALUE), TypeListNode(type=TYPE_BOOL, pass_mode=PARAM_VALUE)];
    let info: FuncInfo = FuncInfo(name="both", base_name="both", ret_type=TYPE_BOOL, arg_types=args, arg_names=["a", "b"], is_varargs=false, abi_name="");
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let types: WirTypeMap = new_wir_type_map();
    wir_lower_function_body(ref types, ref source, ref program, info, body);

    if (types.errors.length() != 0) {
        print("FAIL: valid short-circuit expression was rejected: ", types.errors[0]);
        return 1;
    }
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: lowered short-circuit expression produced invalid WIR: ", errors[0]);
        return 1;
    }

    let text: String = print_wir(program)?;
    catch(err) {
        print("FAIL: lowered short-circuit expression could not be printed");
        return 1;
    }
    let expected: String = "internal func @both(%a:bool, %b:bool) -> bool {\n^entry:\n    %a.addr:ptr<bool> = alloca bool\n    store %a, %a.addr\n    %b.addr:ptr<bool> = alloca bool\n    store %b, %b.addr\n    %5:bool = load %a.addr\n    br %5, ^logic.rhs.0(), ^logic.end.1(false)\n\n^logic.rhs.0:\n    %8:bool = load %b.addr\n    jmp ^logic.end.1(%8)\n\n^logic.end.1(%value:bool):\n    ret %value\n}\n";
    if (text != expected) {
        print("FAIL: lowered short-circuit text is not stable");
        print(text);
        return 1;
    }
    if (!check_nested_logic()) {
        print("FAIL: nested short-circuit expression produced invalid WIR");
        return 1;
    }

    print("PASS: WIR short-circuit logic");
    return 0;
}
