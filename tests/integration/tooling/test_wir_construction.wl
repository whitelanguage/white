// Test: WIR_CONSTRUCTION
// File: tests/integration/tooling/test_wir_construction.wl
// Focus: Lowering value-struct constructors and fixed-array literals as aggregate values.

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

func construction_position() -> Position {
    return Position(idx=0, ln=1, col=1, text="", fn="memory.wl");
}

func construction_token(kind: Int, value: String) -> Token {
    return Token(type=kind, value=value, line=1, col=1);
}

func construction_int(arena: AstArena, value: String, pos: Position) -> NodeID {
    return add_int_node(arena, IntNode(type=NODE_INT, tok=construction_token(TOK_INT, value), pos=pos));
}

func main() -> Int {
    let source: Compiler = Compiler(arena=new_ast_arena(), ptr_base_map=Dict(), array_info_map=Dict(), struct_table=Dict(), struct_id_map=Dict(), named_type_ids=Dict());
    let fields: Vector(Struct) = [FieldInfo(name="x", type=TYPE_INT, llvm_type="", offset=0, is_const=false), FieldInfo(name="y", type=TYPE_INT, llvm_type="", offset=1, is_const=false)];
    let point: StructInfo = StructInfo(name="Point", type_id=103, fields=fields, init_body=NO_NODE, is_class=false, is_enum=false, is_interface=false);
    source.struct_table.put("Point", point);
    source.struct_id_map.put("103", point);
    source.array_info_map.put("104", ArrayInfo(base_type=TYPE_INT, size=3, llvm_name=""));

    let pos: Position = construction_position();
    let point_callee: NodeID = add_var_access_node(source.arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=construction_token(TOK_IDENTIFIER, "Point"), pos=pos));
    let point_call: NodeID = add_call_node(source.arena, CallNode(type=NODE_CALL, callee=point_callee, args=[ArgNode(val=construction_int(source.arena, "7", pos), name="y", is_spread=false), ArgNode(val=construction_int(source.arena, "4", pos), name="x", is_spread=false)], type_args=[], pos=pos, preserve_fallible=false));
    let point_return: NodeID = add_return_node(source.arena, ReturnNode(type=NODE_RETURN, value=point_call, pos=pos));
    let point_body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[point_return]));

    let array_elements: Vector(ArgNode) = [ArgNode(val=construction_int(source.arena, "1", pos), name="", is_spread=false), ArgNode(val=construction_int(source.arena, "2", pos), name="", is_spread=false)];
    let array_literal: NodeID = add_vector_lit_node(source.arena, VectorLitNode(type=NODE_VECTOR_LIT, elements=array_elements, count=2, pos=pos));
    let array_return: NodeID = add_return_node(source.arena, ReturnNode(type=NODE_RETURN, value=array_literal, pos=pos));
    let array_body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[array_return]));

    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let types: WirTypeMap = new_wir_type_map();
    let point_info: FuncInfo = FuncInfo(name="make_point", base_name="make_point", ret_type=103, arg_types=[], arg_names=[], is_varargs=false, abi_name="");
    let array_info: FuncInfo = FuncInfo(name="make_values", base_name="make_values", ret_type=104, arg_types=[], arg_names=[], is_varargs=false, abi_name="");
    wir_lower_function_body(ref types, ref source, ref program, point_info, point_body);
    wir_lower_function_body(ref types, ref source, ref program, array_info, array_body);

    if (types.errors.length() != 0) {
        print("FAIL: valid aggregate construction was rejected: ", types.errors[0]);
        return 1;
    }
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: aggregate construction produced invalid WIR: ", errors[0]);
        return 1;
    }

    let text: String = print_wir(program)?;
    catch(err) {
        print("FAIL: aggregate construction could not be printed");
        return 1;
    }
    let expected: String = "type !Point = {i32, i32}\n\ninternal func @make_point() -> !Point {\n^entry:\n    %3:!Point = struct !Point(4, 7)\n    ret %3\n}\n\ninternal func @make_values() -> [i32; 3] {\n^entry:\n    %7:[i32; 3] = array [1, 2]\n    ret %7\n}\n";
    if (text != expected) {
        print("FAIL: aggregate construction text is not stable");
        print(text);
        return 1;
    }
    print("PASS: WIR aggregate construction");
    return 0;
}
