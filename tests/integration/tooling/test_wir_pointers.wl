// Test: WIR_POINTERS
// File: tests/integration/tooling/test_wir_pointers.wl
// Focus: Lowering ref expressions, pointer loads, indirect stores, and nullptr values.

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

func pointer_position() -> Position {
    return Position(idx=0, ln=1, col=1, text="", fn="memory.wl");
}

func pointer_token(kind: Int, value: String) -> Token {
    return Token(type=kind, value=value, line=1, col=1);
}

func pointer_access(arena: AstArena, name: String, pos: Position) -> NodeID {
    return add_var_access_node(arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=pointer_token(TOK_IDENTIFIER, name), pos=pos));
}

func pointer_int(arena: AstArena, value: String, pos: Position) -> NodeID {
    return add_int_node(arena, IntNode(type=NODE_INT, tok=pointer_token(TOK_INT, value), pos=pos));
}

func main() -> Int {
    let source: Compiler = Compiler(arena=new_ast_arena(), type_counter=100, ptr_cache=Dict(), ptr_base_map=Dict());
    let pos: Position = pointer_position();

    let local: NodeID = add_var_decl_node(source.arena, VarDeclareNode(type=NODE_VAR_DECL, name_tok=pointer_token(TOK_IDENTIFIER, "x"), type_node=NO_NODE, value=pointer_int(source.arena, "5", pos), is_const=false, annotations=[], pos=pos, alloc_id=0));
    let reference: NodeID = add_ref_node(source.arena, RefNode(type=NODE_REF, node=pointer_access(source.arena, "x", pos), pos=pos));
    let pointer_local: NodeID = add_var_decl_node(source.arena, VarDeclareNode(type=NODE_VAR_DECL, name_tok=pointer_token(TOK_IDENTIFIER, "p"), type_node=NO_NODE, value=reference, is_const=false, annotations=[], pos=pos, alloc_id=0));
    let pointer_value: NodeID = add_deref_node(source.arena, DerefNode(type=NODE_DEREF, node=pointer_access(source.arena, "p", pos), level=1, pos=pos));
    let assignment: NodeID = add_ptr_assign_node(source.arena, PtrAssignNode(type=NODE_PTR_ASSIGN, pointer=pointer_value, value=pointer_int(source.arena, "7", pos), pos=pos));
    let pointer_reference: NodeID = add_ref_node(source.arena, RefNode(type=NODE_REF, node=pointer_access(source.arena, "p", pos), pos=pos));
    let pointer_pointer_local: NodeID = add_var_decl_node(source.arena, VarDeclareNode(type=NODE_VAR_DECL, name_tok=pointer_token(TOK_IDENTIFIER, "pp"), type_node=NO_NODE, value=pointer_reference, is_const=false, annotations=[], pos=pos, alloc_id=0));
    let pointer_pointer_value: NodeID = add_deref_node(source.arena, DerefNode(type=NODE_DEREF, node=pointer_access(source.arena, "pp", pos), level=2, pos=pos));
    let pointer_pointer_assignment: NodeID = add_ptr_assign_node(source.arena, PtrAssignNode(type=NODE_PTR_ASSIGN, pointer=pointer_pointer_value, value=pointer_int(source.arena, "9", pos), pos=pos));
    let result: NodeID = add_deref_node(source.arena, DerefNode(type=NODE_DEREF, node=pointer_access(source.arena, "pp", pos), level=2, pos=pos));
    let return_value: NodeID = add_return_node(source.arena, ReturnNode(type=NODE_RETURN, value=result, pos=pos));
    let body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[local, pointer_local, assignment, pointer_pointer_local, pointer_pointer_assignment, return_value]));

    let int_pointer: Int = get_ptr_type_id(ref source, TYPE_INT);
    let null_value: NodeID = add_nullptr_node(source.arena, NullPtrNode(type=NODE_NULLPTR, pos=pos));
    let null_return: NodeID = add_return_node(source.arena, ReturnNode(type=NODE_RETURN, value=null_value, pos=pos));
    let null_body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[null_return]));

    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let types: WirTypeMap = new_wir_type_map();
    let pointer_info: FuncInfo = FuncInfo(name="pointer_ops", base_name="pointer_ops", ret_type=TYPE_INT, arg_types=[], arg_names=[], is_varargs=false, abi_name="");
    let null_info: FuncInfo = FuncInfo(name="null_pointer", base_name="null_pointer", ret_type=int_pointer, arg_types=[], arg_names=[], is_varargs=false, abi_name="");
    wir_lower_function_body(ref types, ref source, ref program, pointer_info, body);
    wir_lower_function_body(ref types, ref source, ref program, null_info, null_body);

    if (types.errors.length() != 0) {
        print("FAIL: valid pointer operations were rejected: ", types.errors[0]);
        return 1;
    }
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: pointer operations produced invalid WIR: ", errors[0]);
        return 1;
    }

    let text: String = print_wir(program)?;
    catch(err) {
        print("FAIL: pointer WIR could not be printed");
        return 1;
    }
    let expected: String = "internal func @pointer_ops() -> i32 {\n^entry:\n    %x.addr:ptr<i32> = alloca i32\n    store 5, %x.addr\n    %p.addr:ptr<ptr<i32>> = alloca ptr<i32>\n    store %x.addr, %p.addr\n    %4:ptr<i32> = load %p.addr\n    check.null %4\n    store 7, %4\n    %pp.addr:ptr<ptr<ptr<i32>>> = alloca ptr<ptr<i32>>\n    store %p.addr, %pp.addr\n    %7:ptr<ptr<i32>> = load %pp.addr\n    check.null %7\n    %8:ptr<i32> = load %7\n    check.null %8\n    store 9, %8\n    %10:ptr<ptr<i32>> = load %pp.addr\n    check.null %10\n    %11:ptr<i32> = load %10\n    check.null %11\n    %12:i32 = load %11\n    ret %12\n}\n\ninternal func @null_pointer() -> ptr<i32> {\n^entry:\n    %15:ptr<i32> = cast null\n    ret %15\n}\n";
    if (text != expected) {
        print("FAIL: lowered pointer text is not stable");
        print(text);
        return 1;
    }
    print("PASS: WIR pointer lowering");
    return 0;
}
