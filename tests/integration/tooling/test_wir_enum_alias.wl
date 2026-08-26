// Test: WIR_ENUM_ALIAS
// File: tests/integration/tooling/test_wir_enum_alias.wl
// Focus: Resolving enum members through a qualified module alias.

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

func enum_alias_token(value: String) -> Token {
    return Token(type=TOK_IDENTIFIER, value=value, line=1, col=1);
}

func main() -> Int {
    let pos: Position = Position(idx=0, ln=1, col=1, text="", fn="memory.wl");
    let visible: Dict(String, String) = Dict();
    visible.put("platform_errors", "errors.");
    let structs: Dict(String, StructInfo) = Dict();
    structs.put("100", StructInfo(name="errors.Kind", type_id=100, is_enum=true));
    let source: Compiler = Compiler(arena=new_ast_arena(), ptr_base_map=Dict(), struct_id_map=structs, current_file_visible_prefixes=visible, current_file_type_aliases=Dict(), global_type_aliases=Dict());

    let root: NodeID = add_var_access_node(source.arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=enum_alias_token("platform_errors"), pos=pos));
    let owner: NodeID = add_field_access_node(source.arena, FieldAccessNode(type=NODE_FIELD_ACCESS, obj=root, field_name="Kind", pos=pos));
    let member: NodeID = add_field_access_node(source.arena, FieldAccessNode(type=NODE_FIELD_ACCESS, obj=owner, field_name="Interrupted", pos=pos));
    let result: NodeID = add_return_node(source.arena, ReturnNode(type=NODE_RETURN, value=member, pos=pos));
    let body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[result]));
    let info: FuncInfo = FuncInfo(name="interrupt_kind", base_name="interrupt_kind", ret_type=100, arg_types=[], arg_names=[], is_varargs=false, abi_name="");

    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let types: WirTypeMap = new_wir_type_map();
    types.enum_values.put("errors.Kind.Interrupted", WirEnumValue(source_type=100, value=7L));
    wir_lower_function_body(ref types, ref source, ref program, info, body);
    if (types.errors.length() != 0) { print("FAIL: WIR enum alias lowering: ", types.errors[0]); return 1; }
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) { print("FAIL: WIR enum alias verification: ", errors[0]); return 1; }
    let text: String = print_wir(program)?;
    catch(err) { print("FAIL: WIR enum alias could not be printed"); return 1; }
    if (text != "internal func @interrupt_kind() -> i32 {\n^entry:\n    ret 7\n}\n") {
        print("FAIL: WIR enum alias value");
        return 1;
    }
    print("PASS: WIR enum alias");
    return 0;
}
