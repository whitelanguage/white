// Test: WIR_ANALYSIS
// File: tests/integration/tooling/test_wir_analysis.wl
// Focus: Resolving struct fields before either backend starts lowering.

import * from "../../../src/compiler/context.wl"
import * from "../../../src/compiler/analysis.wl"
import * from "../../../src/compiler/wir/model.wl"
import new_wir_module from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/lowering/types.wl"
import * from "../../../src/frontend/ast.wl"
import * from "../../../src/frontend/arena.wl"
import * from "../../../src/frontend/tokens.wl"
import Position, GLOBAL_ERROR_COUNT from "../../../src/frontend/diagnostics.wl"

func analysis_token(value: String) -> Token {
    return Token(type=TOK_IDENTIFIER, value=value, line=1, col=1);
}

func analysis_type(arena: AstArena, value: String, pos: Position) -> NodeID {
    return add_var_access_node(arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=analysis_token(value), pos=pos));
}

func main() -> Int {
    let arena: AstArena = new_ast_arena();
    let structs: Dict(String, StructInfo) = Dict();
    let struct_ids: Dict(String, StructInfo) = Dict();
    let info: StructInfo = StructInfo(name="Pair", type_id=100, fields=null, llvm_name="%struct.Pair", init_body=NO_NODE, is_class=false, is_enum=false, is_interface=false);
    structs.put("Pair", info);
    struct_ids.put("100", info);
    let source: Compiler = Compiler(arena=arena, struct_table=structs, struct_id_map=struct_ids, named_types=Dict(), named_type_ids=Dict(), generic_bindings=Dict(), ptr_base_map=Dict(), array_info_map=Dict(), vector_base_map=Dict(), fallible_base_map=Dict(), func_ret_map=Dict(), method_ret_map=Dict(), current_package_prefix="", all_modules=[]);
    let pos: Position = Position(idx=0, ln=1, col=1, text="", fn="memory.wl");
    let fields: Vector(ParamNode) = [
        ParamNode(type=NODE_PARAM, name_tok=analysis_token("left"), type_tok=analysis_type(arena, "Int", pos), pos=pos, pass_mode=PARAM_VALUE, is_variadic=false, default_val=NO_NODE),
        ParamNode(type=NODE_PARAM, name_tok=analysis_token("right"), type_tok=analysis_type(arena, "Long", pos), pos=pos, pass_mode=PARAM_VALUE, is_variadic=false, default_val=NO_NODE)
    ];
    let node: StructDefNode = StructDefNode(type=NODE_STRUCT_DEF, name_tok=analysis_token("Pair"), type_params=[], fields=fields, body=NO_NODE, annotations=[], pos=pos);
    let definition: NodeID = add_struct_def_node(arena, node);
    let root: NodeID = add_block_node(arena, BlockNode(type=NODE_BLOCK, stmts=[definition]));
    source.all_modules.append(ParsedModule(path="memory.wl", prefix="", dir="", is_package=false, ast=root, visible=Dict(), namespaces=Dict(), types=Dict(), funcs=Dict(), globals=Dict(), imports=[]));

    analyze_declarations(ref source);
    if (GLOBAL_ERROR_COUNT > 0) {
        print("FAIL: backend-independent struct analysis failed");
        return 1;
    }
    info = source.struct_table.lookup("Pair");
    let left: FieldInfo = info.fields[0];
    let right: FieldInfo = info.fields[1];
    if (info.fields.length() != 2 || left.type != TYPE_INT || right.type != TYPE_LONG) {
        print("FAIL: struct field types were not resolved");
        return 1;
    }
    if (left.llvm_type.length() != 0 || right.llvm_type.length() != 0) {
        print("FAIL: semantic analysis leaked an LLVM type into struct metadata");
        return 1;
    }

    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let types: WirTypeMap = new_wir_type_map();
    let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, 100);
    if (type_id == NO_WIR_TYPE || types.errors.length() != 0) {
        print("FAIL: WIR could not consume analyzed struct metadata");
        return 1;
    }
    let wir_type: WirType = program.arena.types[wir_id_index(UInt32(type_id))];
    if (wir_type.fields.length() != 2) {
        print("FAIL: analyzed struct layout was not preserved in WIR");
        return 1;
    }

    let class_info: StructInfo = StructInfo(name="Box", type_id=101, fields=null, llvm_name="%class.Box", init_body=NO_NODE, is_class=true, is_enum=false, is_interface=false, vtable=null, interfaces=null);
    source.struct_table.put("Box", class_info);
    source.struct_id_map.put("101", class_info);
    let default_value: NodeID = add_int_node(arena, IntNode(type=NODE_INT, tok=Token(type=TOK_INT, value="1", line=1, col=1), pos=pos));
    let class_field: NodeID = add_var_decl_node(arena, VarDeclareNode(type=NODE_VAR_DECL, name_tok=analysis_token("value"), type_node=analysis_type(arena, "Int", pos), value=default_value, is_const=false, annotations=[], pos=pos, alloc_id=0));
    let class_node: NodeID = add_class_def_node(arena, ClassDefNode(type=NODE_CLASS_DEF, pos=pos, name_tok=analysis_token("Box"), type_params=[], parent_tok=NO_NODE, interfaces=[], fields=[class_field], methods=[], annotations=[]));
    let class_root: NodeID = add_block_node(arena, BlockNode(type=NODE_BLOCK, stmts=[class_node]));
    source.all_modules.append(ParsedModule(path="class.wl", prefix="", dir="", is_package=false, ast=class_root, visible=Dict(), namespaces=Dict(), types=Dict(), funcs=Dict(), globals=Dict(), imports=[]));
    analyze_declarations(ref source);

    class_info = source.struct_table.lookup("Box");
    let vptr_field: FieldInfo = class_info.fields[0];
    let value_field: FieldInfo = class_info.fields[1];
    if (class_info.fields.length() != 2 || vptr_field.name != "_vptr" || value_field.type != TYPE_INT) {
        print("FAIL: class layout was not resolved before backend lowering");
        return 1;
    }
    if (vptr_field.llvm_type.length() != 0 || value_field.llvm_type.length() != 0) {
        print("FAIL: class analysis leaked LLVM types into semantic metadata");
        return 1;
    }
    let class_type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, 101);
    let class_pointer: WirType = program.arena.types[wir_id_index(UInt32(class_type_id))];
    let class_record: WirType = program.arena.types[wir_id_index(UInt32(class_pointer.element))];
    if (class_pointer.kind != WirTypeKind.Pointer || class_record.fields.length() != 2) {
        print("FAIL: WIR could not consume analyzed class metadata");
        return 1;
    }
    print("PASS: backend-independent declaration analysis");
    return 0;
}
