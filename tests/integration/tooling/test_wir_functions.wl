// Test: WIR_FUNCTIONS
// File: tests/integration/tooling/test_wir_functions.wl
// Focus: Lowering resolved parameters, locals, arithmetic and returns from the frontend AST.

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

func test_position() -> Position {
    return Position(idx=0, ln=1, col=1, text="", fn="memory.wl");
}

func test_token(kind: Int, value: String) -> Token {
    return Token(type=kind, value=value, line=1, col=1);
}

func main() -> Int {
    let source: Compiler = Compiler(arena=new_ast_arena(), ptr_base_map=Dict());
    let pos: Position = test_position();
    let left: NodeID = add_var_access_node(source.arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=test_token(TOK_IDENTIFIER, "a"), pos=pos));
    let right: NodeID = add_var_access_node(source.arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=test_token(TOK_IDENTIFIER, "b"), pos=pos));
    let sum_value: NodeID = add_binop_node(source.arena, BinOpNode(type=NODE_BINOP, left=left, op_tok=test_token(TOK_PLUS, "+"), right=right, pos=pos));
    let sum: NodeID = add_var_decl_node(source.arena, VarDeclareNode(type=NODE_VAR_DECL, name_tok=test_token(TOK_IDENTIFIER, "sum"), type_node=NO_NODE, value=sum_value, is_const=false, annotations=[], pos=pos, alloc_id=0));
    let sum_access: NodeID = add_var_access_node(source.arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=test_token(TOK_IDENTIFIER, "sum"), pos=pos));
    let return_sum: NodeID = add_return_node(source.arena, ReturnNode(type=NODE_RETURN, value=sum_access, pos=pos));
    let body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[sum, return_sum]));

    let args: Vector(Struct) = [TypeListNode(type=TYPE_INT, pass_mode=PARAM_VALUE), TypeListNode(type=TYPE_INT, pass_mode=PARAM_VALUE)];
    let info: FuncInfo = FuncInfo(name="add", base_name="add", ret_type=TYPE_INT, arg_types=args, arg_names=["a", "b"], is_varargs=false, abi_name="");
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let types: WirTypeMap = new_wir_type_map();
    wir_lower_function_body(ref types, ref source, ref program, info, body);

    if (types.errors.length() != 0) {
        print("FAIL: valid function body was rejected: ", types.errors[0]);
        return 1;
    }
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: lowered function body produced invalid WIR: ", errors[0]);
        return 1;
    }

    let text: String = print_wir(program)?;
    catch(err) {
        print("FAIL: lowered function body could not be printed");
        return 1;
    }
    let expected: String = "internal func @add(%a:i32, %b:i32) -> i32 {\n^entry:\n    %a.addr:ptr<i32> = alloca i32\n    store %a, %a.addr\n    %b.addr:ptr<i32> = alloca i32\n    store %b, %b.addr\n    %5:i32 = load %a.addr\n    %6:i32 = load %b.addr\n    %7:i32 = add %5, %6\n    %sum.addr:ptr<i32> = alloca i32\n    store %7, %sum.addr\n    %9:i32 = load %sum.addr\n    ret %9\n}\n";
    if (text != expected) {
        print("FAIL: lowered function text is not stable");
        print(text);
        return 1;
    }

    print("PASS: WIR function lowering");
    return 0;
}
