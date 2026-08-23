// Test: WIR_REFERENCES
// File: tests/integration/tooling/test_wir_refs.wl
// Focus: Preserving explicit ref parameters as typed addresses across White calls.

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

func ref_position() -> Position {
    return Position(idx=0, ln=1, col=1, text="", fn="memory.wl");
}

func ref_token(kind: Int, value: String) -> Token {
    return Token(type=kind, value=value, line=1, col=1);
}

func ref_access(arena: AstArena, name: String, pos: Position) -> NodeID {
    return add_var_access_node(arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=ref_token(TOK_IDENTIFIER, name), pos=pos));
}

func main() -> Int {
    let source: Compiler = Compiler(arena=new_ast_arena(), ptr_base_map=Dict(), func_table=Dict());
    let pos: Position = ref_position();
    let ref_args: Vector(Struct) = [TypeListNode(type=TYPE_INT, pass_mode=PARAM_REF)];
    let read_info: FuncInfo = FuncInfo(name="read_ref", base_name="read_ref", ret_type=TYPE_INT, arg_types=ref_args, arg_names=["value"], is_varargs=false, abi_name="");
    source.func_table.put("read_ref", read_info);

    let read_return: NodeID = add_return_node(source.arena, ReturnNode(type=NODE_RETURN, value=ref_access(source.arena, "value", pos), pos=pos));
    let read_body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[read_return]));

    let seven: NodeID = add_int_node(source.arena, IntNode(type=NODE_INT, tok=ref_token(TOK_INT, "7"), pos=pos));
    let local: NodeID = add_var_decl_node(source.arena, VarDeclareNode(type=NODE_VAR_DECL, name_tok=ref_token(TOK_IDENTIFIER, "x"), type_node=NO_NODE, value=seven, is_const=false, annotations=[], pos=pos, alloc_id=0));
    let reference: NodeID = add_ref_node(source.arena, RefNode(type=NODE_REF, node=ref_access(source.arena, "x", pos), pos=pos));
    let callee: NodeID = add_var_access_node(source.arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=ref_token(TOK_IDENTIFIER, "read_ref"), pos=pos));
    let call: NodeID = add_call_node(source.arena, CallNode(type=NODE_CALL, callee=callee, args=[ArgNode(val=reference, name="", is_spread=false)], type_args=[], pos=pos, preserve_fallible=false));
    let caller_return: NodeID = add_return_node(source.arena, ReturnNode(type=NODE_RETURN, value=call, pos=pos));
    let caller_body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[local, caller_return]));

    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let types: WirTypeMap = new_wir_type_map();
    wir_lower_function_body(ref types, ref source, ref program, read_info, read_body);
    let caller_info: FuncInfo = FuncInfo(name="call_ref", base_name="call_ref", ret_type=TYPE_INT, arg_types=[], arg_names=[], is_varargs=false, abi_name="");
    wir_lower_function_body(ref types, ref source, ref program, caller_info, caller_body);

    if (types.errors.length() != 0) {
        print("FAIL: valid reference call was rejected: ", types.errors[0]);
        return 1;
    }
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: lowered reference call produced invalid WIR: ", errors[0]);
        return 1;
    }

    let text: String = print_wir(program)?;
    catch(err) {
        print("FAIL: lowered reference call could not be printed");
        return 1;
    }
    let expected: String = "internal func @read_ref(%value:ptr<i32>) -> i32 {\n^entry:\n    %2:i32 = load %value\n    ret %2\n}\n\ninternal func @call_ref() -> i32 {\n^entry:\n    %x.addr:ptr<i32> = alloca i32\n    store 7, %x.addr\n    %6:i32 = call @read_ref(%x.addr)\n    ret %6\n}\n";
    if (text != expected) {
        print("FAIL: lowered reference text is not stable");
        print(text);
        return 1;
    }

    print("PASS: WIR references");
    return 0;
}
