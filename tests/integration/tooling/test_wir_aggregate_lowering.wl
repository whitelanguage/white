// Test: WIR_AGGREGATE_LOWERING
// File: tests/integration/tooling/test_wir_aggregate_lowering.wl
// Focus: Lowering value-struct fields and fixed-array indexing from the resolved AST.

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

func aggregate_position() -> Position {
    return Position(idx=0, ln=1, col=1, text="", fn="memory.wl");
}

func aggregate_token(kind: Int, value: String) -> Token {
    return Token(type=kind, value=value, line=1, col=1);
}

func aggregate_access(arena: AstArena, name: String, pos: Position) -> NodeID {
    return add_var_access_node(arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=aggregate_token(TOK_IDENTIFIER, name), pos=pos));
}

func main() -> Int {
    let source: Compiler = Compiler(arena=new_ast_arena(), ptr_base_map=Dict(), array_info_map=Dict(), struct_id_map=Dict(), named_type_ids=Dict());
    let fields: Vector(Struct) = [FieldInfo(name="x", type=TYPE_INT, llvm_type="", offset=0, is_const=false), FieldInfo(name="y", type=TYPE_INT, llvm_type="", offset=1, is_const=false)];
    source.struct_id_map.put("103", StructInfo(name="Point", type_id=103, fields=fields, is_class=false, is_enum=false, is_interface=false));
    source.array_info_map.put("104", ArrayInfo(base_type=TYPE_INT, size=4, llvm_name=""));

    let pos: Position = aggregate_position();
    let seven: NodeID = add_int_node(source.arena, IntNode(type=NODE_INT, tok=aggregate_token(TOK_INT, "7"), pos=pos));
    let set_x: NodeID = add_field_assign_node(source.arena, FieldAssignNode(type=NODE_FIELD_ASSIGN, obj=aggregate_access(source.arena, "point", pos), field_name="x", value=seven, pos=pos));
    let point_x: NodeID = add_field_access_node(source.arena, FieldAccessNode(type=NODE_FIELD_ACCESS, obj=aggregate_access(source.arena, "point", pos), field_name="x", pos=pos));
    let set_value: NodeID = add_index_assign_node(source.arena, IndexAssignNode(type=NODE_INDEX_ASSIGN, target=aggregate_access(source.arena, "values", pos), index_node=aggregate_access(source.arena, "i", pos), value=point_x, pos=pos));
    let result: NodeID = add_index_access_node(source.arena, IndexAccessNode(type=NODE_INDEX_ACCESS, target=aggregate_access(source.arena, "values", pos), index_node=aggregate_access(source.arena, "i", pos), pos=pos));
    let return_value: NodeID = add_return_node(source.arena, ReturnNode(type=NODE_RETURN, value=result, pos=pos));
    let body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[set_x, set_value, return_value]));

    let args: Vector(Struct) = [TypeListNode(type=103, pass_mode=PARAM_VALUE), TypeListNode(type=104, pass_mode=PARAM_VALUE), TypeListNode(type=TYPE_INT, pass_mode=PARAM_VALUE)];
    let info: FuncInfo = FuncInfo(name="aggregate_lowering", base_name="aggregate_lowering", ret_type=TYPE_INT, arg_types=args, arg_names=["point", "values", "i"], is_varargs=false, abi_name="");
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let types: WirTypeMap = new_wir_type_map();
    wir_lower_function_body(ref types, ref source, ref program, info, body);

    if (types.errors.length() != 0) {
        print("FAIL: valid aggregate AST was rejected: ", types.errors[0]);
        return 1;
    }
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: aggregate AST produced invalid WIR: ", errors[0]);
        return 1;
    }

    let text: String = print_wir(program)?;
    catch(err) {
        print("FAIL: lowered aggregate WIR could not be printed");
        return 1;
    }
    let expected: String = "type !Point = {i32, i32}\n\ninternal func @aggregate_lowering(%point:!Point, %values:[i32; 4], %i:i32) -> i32 {\n^entry:\n    %point.addr:ptr<!Point> = alloca !Point\n    store %point, %point.addr\n    %values.addr:ptr<[i32; 4]> = alloca [i32; 4]\n    store %values, %values.addr\n    %i.addr:ptr<i32> = alloca i32\n    store %i, %i.addr\n    %8:ptr<i32> = field.addr %point.addr, 0\n    store 7, %8\n    %10:i32 = load %i.addr\n    check.bounds %10, 4\n    %12:ptr<i32> = index.addr %values.addr, %10\n    %13:!Point = load %point.addr\n    %15:i32 = field %13, 0\n    store %15, %12\n    %16:i32 = load %i.addr\n    check.bounds %16, 4\n    %18:ptr<i32> = index.addr %values.addr, %16\n    %19:i32 = load %18\n    ret %19\n}\n";
    if (text != expected) {
        print("FAIL: lowered aggregate text is not stable");
        print(text);
        return 1;
    }
    print("PASS: WIR aggregate lowering");
    return 0;
}
