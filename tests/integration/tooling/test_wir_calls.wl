// Test: WIR_CALLS
// File: tests/integration/tooling/test_wir_calls.wl
// Focus: Lowering a resolved direct call without rebuilding overload resolution in WIR.

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

func call_position() -> Position {
    return Position(idx=0, ln=1, col=1, text="", fn="memory.wl");
}

func call_token(kind: Int, value: String) -> Token {
    return Token(type=kind, value=value, line=1, col=1);
}

func main() -> Int {
    let source: Compiler = Compiler(arena=new_ast_arena(), ptr_base_map=Dict(), func_table=Dict());
    let pos: Position = call_position();
    let abs_args: Vector(Struct) = [TypeListNode(type=TYPE_INT, pass_mode=PARAM_VALUE)];
    let abs_info: FuncInfo = FuncInfo(name="abs", base_name="abs", ret_type=TYPE_INT, arg_types=abs_args, arg_names=["value"], is_varargs=false, abi_name="C");
    source.func_table.put("abs", abs_info);

    let callee: NodeID = add_var_access_node(source.arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=call_token(TOK_IDENTIFIER, "abs"), pos=pos));
    let seven: NodeID = add_int_node(source.arena, IntNode(type=NODE_INT, tok=call_token(TOK_INT, "7"), pos=pos));
    let call: NodeID = add_call_node(source.arena, CallNode(type=NODE_CALL, callee=callee, args=[ArgNode(val=seven, name="", is_spread=false)], type_args=[], pos=pos, preserve_fallible=false));
    let result: NodeID = add_return_node(source.arena, ReturnNode(type=NODE_RETURN, value=call, pos=pos));
    let body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[call, result]));

    let caller: FuncInfo = FuncInfo(name="call_abs", base_name="call_abs", ret_type=TYPE_INT, arg_types=[], arg_names=[], is_varargs=false, abi_name="");
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let types: WirTypeMap = new_wir_type_map();
    wir_lower_function_body(ref types, ref source, ref program, caller, body);

    if (types.errors.length() != 0) {
        print("FAIL: valid direct call was rejected: ", types.errors[0]);
        return 1;
    }
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: lowered direct call produced invalid WIR: ", errors[0]);
        return 1;
    }

    let text: String = print_wir(program)?;
    catch(err) {
        print("FAIL: lowered direct call could not be printed");
        return 1;
    }
    let expected: String = "internal func @call_abs() -> i32 {\n^entry:\n    %4:i32 = call @abs(7)\n    %6:i32 = call @abs(7)\n    ret %6\n}\n\nextern c func @abs(i32) -> i32\n";
    if (text != expected) {
        print("FAIL: lowered call text is not stable");
        print(text);
        return 1;
    }

    print("PASS: WIR calls");
    return 0;
}
