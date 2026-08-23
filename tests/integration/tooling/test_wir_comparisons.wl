// Test: WIR_COMPARISONS
// File: tests/integration/tooling/test_wir_comparisons.wl
// Focus: Preserving signed, unsigned and floating-point comparison semantics in WIR.

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

func comparison_position() -> Position {
    return Position(idx=0, ln=1, col=1, text="", fn="memory.wl");
}

func comparison_token(kind: Int, value: String) -> Token {
    return Token(type=kind, value=value, line=1, col=1);
}

func check_comparison(source_type: Int, token_kind: Int, token_value: String, wir_type: String, opcode: String) -> Bool {
    let source: Compiler = Compiler(arena=new_ast_arena(), ptr_base_map=Dict());
    let pos: Position = comparison_position();
    let left: NodeID = add_var_access_node(source.arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=comparison_token(TOK_IDENTIFIER, "a"), pos=pos));
    let right: NodeID = add_var_access_node(source.arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=comparison_token(TOK_IDENTIFIER, "b"), pos=pos));
    let comparison: NodeID = add_binop_node(source.arena, BinOpNode(type=NODE_BINOP, left=left, op_tok=comparison_token(token_kind, token_value), right=right, pos=pos));
    let result: NodeID = add_return_node(source.arena, ReturnNode(type=NODE_RETURN, value=comparison, pos=pos));
    let body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[result]));

    let args: Vector(Struct) = [TypeListNode(type=source_type, pass_mode=PARAM_VALUE), TypeListNode(type=source_type, pass_mode=PARAM_VALUE)];
    let info: FuncInfo = FuncInfo(name="compare", base_name="compare", ret_type=TYPE_BOOL, arg_types=args, arg_names=["a", "b"], is_varargs=false, abi_name="");
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let types: WirTypeMap = new_wir_type_map();
    wir_lower_function_body(ref types, ref source, ref program, info, body);
    if (types.errors.length() != 0) { return false; }
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) { return false; }

    let text: String = print_wir(program)?;
    catch(err) { return false; }
    let expected: String = "internal func @compare(%a:" + wir_type + ", %b:" + wir_type + ") -> bool {\n^entry:\n    %a.addr:ptr<" + wir_type + "> = alloca " + wir_type + "\n    store %a, %a.addr\n    %b.addr:ptr<" + wir_type + "> = alloca " + wir_type + "\n    store %b, %b.addr\n    %5:" + wir_type + " = load %a.addr\n    %6:" + wir_type + " = load %b.addr\n    %7:bool = " + opcode + " %5, %6\n    ret %7\n}\n";
    return text == expected;
}

func main() -> Int {
    if (!check_comparison(TYPE_INT, TOK_LTE, "<=", "i32", "sle")) {
        print("FAIL: signed comparison lowering");
        return 1;
    }
    if (!check_comparison(TYPE_UINT32, TOK_GT, ">", "u32", "ugt")) {
        print("FAIL: unsigned comparison lowering");
        return 1;
    }
    if (!check_comparison(TYPE_FLOAT, TOK_GTE, ">=", "f64", "fge")) {
        print("FAIL: floating-point comparison lowering");
        return 1;
    }

    print("PASS: WIR comparisons");
    return 0;
}
