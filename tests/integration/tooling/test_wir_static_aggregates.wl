// Test: WIR_STATIC_AGGREGATES
// File: tests/integration/tooling/test_wir_static_aggregates.wl
// Focus: Lowering nested fixed arrays and value structs into static WIR constants.

import * from "../../../src/compiler/context.wl"
import * from "../../../src/frontend/ast.wl"
import * from "../../../src/frontend/arena.wl"
import * from "../../../src/frontend/tokens.wl"
import Position from "../../../src/frontend/diagnostics.wl"
import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/verify.wl"
import * from "../../../src/compiler/wir/backend/llvm.wl"
import * from "../../../src/compiler/wir/lowering/types.wl"
import * from "../../../src/compiler/wir/lowering/static_data.wl"

func static_position() -> Position {
    return Position(idx=0, ln=1, col=1, text="", fn="memory.wl");
}

func static_token(kind: Int, value: String) -> Token {
    return Token(type=kind, value=value, line=1, col=1);
}

func static_access(arena: AstArena, name: String, pos: Position) -> NodeID {
    return add_var_access_node(arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=static_token(TOK_IDENTIFIER, name), pos=pos));
}

func static_point(arena: AstArena, value: String, pos: Position) -> NodeID {
    let number: NodeID = add_int_node(arena, IntNode(type=NODE_INT, tok=static_token(TOK_INT, value), pos=pos));
    let text: NodeID = add_string_node(arena, StringNode(type=NODE_STRING, tok=static_token(TOK_STR_LIT, "point"), pos=pos));
    let args: Vector(ArgNode) = [ArgNode(val=number, name="", is_spread=false), ArgNode(val=text, name="", is_spread=false)];
    return add_call_node(arena, CallNode(type=NODE_CALL, callee=static_access(arena, "Point", pos), args=args, type_args=[], pos=pos, preserve_fallible=false));
}

func main() -> Int {
    let point_type: Int = 100;
    let array_type: Int = 101;
    let buffer_type: Int = 102;
    let structs: Dict(String, StructInfo) = Dict();
    let arrays: Dict(String, ArrayInfo) = Dict();
    let named: Dict(String, NamedTypeInfo) = Dict();
    let fields: Vector(Struct) = [
        FieldInfo(name="x", type=TYPE_INT, llvm_type="", offset=0, is_const=false),
        FieldInfo(name="label", type=TYPE_STRING, llvm_type="", offset=1, is_const=false)
    ];
    structs.put("" + point_type, StructInfo(name="Point", type_id=point_type, fields=fields, is_class=false, is_enum=false, is_interface=false));
    arrays.put("" + array_type, ArrayInfo(base_type=point_type, size=2, llvm_name=""));
    arrays.put("" + buffer_type, ArrayInfo(base_type=TYPE_BYTE, size=4096, llvm_name=""));
    let source: Compiler = Compiler(arena=new_ast_arena(), struct_id_map=structs, array_info_map=arrays, named_type_ids=named);
    let pos: Position = static_position();
    let literal: NodeID = add_vector_lit_node(source.arena, VectorLitNode(type=NODE_VECTOR_LIT, elements=[ArgNode(val=static_point(source.arena, "1", pos), name="", is_spread=false), ArgNode(val=static_point(source.arena, "2", pos), name="", is_spread=false)], count=2, pos=pos));

    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let types: WirTypeMap = new_wir_type_map();
    let initializer: WirValueID = wir_lower_static_value(ref types, ref source, ref program, literal, array_type, pos);
    if (initializer == NO_WIR_VALUE || types.errors.length() != 0) { print("FAIL: static aggregate lowering failed"); return 1; }
    let lowered_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, array_type);
    wir_add_aligned_global(ref program, "points", lowered_type, initializer, WirLinkage.Internal, true, 8);
    let empty: NodeID = add_vector_lit_node(source.arena, VectorLitNode(type=NODE_VECTOR_LIT, elements=[], count=0, pos=pos));
    let zero: WirValueID = wir_lower_static_value(ref types, ref source, ref program, empty, buffer_type, pos);
    if (zero == NO_WIR_VALUE || types.errors.length() != 0) { print("FAIL: empty static array lowering failed"); return 1; }
    let lowered_buffer: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, buffer_type);
    wir_add_aligned_global(ref program, "buffer", lowered_buffer, zero, WirLinkage.Internal, false, 16);

    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) { print("FAIL: static aggregate WIR is invalid: ", errors[0]); return 1; }
    if (program.arena.constants.length() != 9 || program.arena.globals.length() != 4) {
        print("FAIL: nested constants or String data were not deduplicated");
        return 1;
    }
    let emitted: WirLLVMResult = emit_wir_llvm(program)?;
    catch(err) { print("FAIL: static aggregate LLVM emission failed"); return 1; }
    if (emitted.errors.length() != 0) { print("FAIL: static aggregate LLVM emission was rejected"); return 1; }

    print("PASS: WIR static aggregate lowering");
    return 0;
}
