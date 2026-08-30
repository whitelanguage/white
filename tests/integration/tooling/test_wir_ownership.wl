// Test: WIR_OWNERSHIP
// File: tests/integration/tooling/test_wir_ownership.wl
// Focus: Lowering owned parameters, local copies, returns, and value-struct fields.

import * from "../../../src/compiler/context.wl"
import * from "../../../src/frontend/ast.wl"
import * from "../../../src/frontend/arena.wl"
import * from "../../../src/frontend/tokens.wl"
import Position from "../../../src/frontend/diagnostics.wl"
import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/verify.wl"
import * from "../../../src/compiler/wir/lowering/types.wl"
import * from "../../../src/compiler/wir/lowering/functions.wl"

func ownership_position() -> Position {
    return Position(idx=0, ln=1, col=1, text="", fn="memory.wl");
}

func ownership_token(kind: Int, value: String) -> Token {
    return Token(type=kind, value=value, line=1, col=1);
}

func ownership_access(arena: AstArena, name: String, pos: Position) -> NodeID {
    return add_var_access_node(arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=ownership_token(TOK_IDENTIFIER, name), pos=pos));
}

func ownership_copy_body(arena: AstArena, source_name: String, pos: Position) -> NodeID {
    let local: NodeID = add_var_decl_node(arena, VarDeclareNode(type=NODE_VAR_DECL, name_tok=ownership_token(TOK_IDENTIFIER, "copy"), type_node=NO_NODE, value=ownership_access(arena, source_name, pos), is_const=false, annotations=[], pos=pos, alloc_id=0));
    let assignment: NodeID = add_var_assign_node(arena, VarAssignNode(type=NODE_VAR_ASSIGN, name_tok=ownership_token(TOK_IDENTIFIER, "copy"), value=ownership_access(arena, "copy", pos), pos=pos));
    let result: NodeID = add_return_node(arena, ReturnNode(type=NODE_RETURN, value=ownership_access(arena, "copy", pos), pos=pos));
    return add_block_node(arena, BlockNode(type=NODE_BLOCK, stmts=[local, assignment, result]));
}

func ownership_discard_body(arena: AstArena, pos: Position) -> NodeID {
    let literal: NodeID = add_string_node(arena, StringNode(type=NODE_STRING, tok=ownership_token(TOK_STR_LIT, "temporary"), pos=pos));
    let call: NodeID = add_call_node(arena, CallNode(type=NODE_CALL, callee=ownership_access(arena, "copy_string", pos), args=[ArgNode(val=literal, name="", is_spread=false)], type_args=[], pos=pos, preserve_fallible=false));
    let zero: NodeID = add_int_node(arena, IntNode(type=NODE_INT, tok=ownership_token(TOK_INT, "0"), pos=pos));
    let result: NodeID = add_return_node(arena, ReturnNode(type=NODE_RETURN, value=zero, pos=pos));
    return add_block_node(arena, BlockNode(type=NODE_BLOCK, stmts=[call, result]));
}

func ownership_opcode_count(program: WirModule, function_id: WirFuncID, opcode: WirOpcode) -> Int {
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let count: Int = 0;
    let i: Int = 0;
    while (i < function.blocks.length()) {
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(function.blocks[i]))];
        let j: Int = 0;
        while (j < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[j]))];
            if (instruction.opcode == opcode) { count++; }
            j++;
        }
        i++;
    }
    return count;
}

func main() -> Int {
    let source: Compiler = Compiler(arena=new_ast_arena(), ptr_base_map=Dict(), array_info_map=Dict(), vector_base_map=Dict(), fallible_base_map=Dict(), func_ret_map=Dict(), method_ret_map=Dict(), struct_id_map=Dict(), named_type_ids=Dict(), func_table=Dict());
    let pos: Position = ownership_position();
    let holder_type: Int = 103;
    let string_array_type: Int = 104;
    source.struct_id_map.put("" + TYPE_STRING, StructInfo(name="$String", type_id=TYPE_STRING, fields=[], is_class=false, is_enum=false, is_interface=false));
    let fields: Vector(Struct) = [FieldInfo(name="text", type=TYPE_STRING, llvm_type="", offset=0, is_const=false)];
    source.struct_id_map.put("" + holder_type, StructInfo(name="Holder", type_id=holder_type, fields=fields, is_class=false, is_enum=false, is_interface=false));
    source.array_info_map.put("" + string_array_type, ArrayInfo(base_type=TYPE_STRING, size=2, llvm_name=""));

    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let types: WirTypeMap = new_wir_type_map();
    let string_info: FuncInfo = FuncInfo(name="copy_string", base_name="copy_string", ret_type=TYPE_STRING, arg_types=[TypeListNode(type=TYPE_STRING, pass_mode=PARAM_VALUE)], arg_names=["value"], is_varargs=false, abi_name="");
    let holder_info: FuncInfo = FuncInfo(name="copy_holder", base_name="copy_holder", ret_type=holder_type, arg_types=[TypeListNode(type=holder_type, pass_mode=PARAM_VALUE)], arg_names=["value"], is_varargs=false, abi_name="");
    let array_info: FuncInfo = FuncInfo(name="copy_string_array", base_name="copy_string_array", ret_type=string_array_type, arg_types=[TypeListNode(type=string_array_type, pass_mode=PARAM_VALUE)], arg_names=["value"], is_varargs=false, abi_name="");
    let discard_info: FuncInfo = FuncInfo(name="discard_string", base_name="discard_string", ret_type=TYPE_INT, arg_types=[], arg_names=[], is_varargs=false, abi_name="");
    source.func_table.put("copy_string", string_info);
    let string_id: WirFuncID = wir_lower_function_body(ref types, ref source, ref program, string_info, ownership_copy_body(source.arena, "value", pos));
    let holder_id: WirFuncID = wir_lower_function_body(ref types, ref source, ref program, holder_info, ownership_copy_body(source.arena, "value", pos));
    let array_id: WirFuncID = wir_lower_function_body(ref types, ref source, ref program, array_info, ownership_copy_body(source.arena, "value", pos));
    let discard_id: WirFuncID = wir_lower_function_body(ref types, ref source, ref program, discard_info, ownership_discard_body(source.arena, pos));

    if (types.errors.length() != 0) {
        print("FAIL: ownership lowering rejected a valid copy: ", types.errors[0]);
        return 1;
    }
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: ownership lowering produced invalid WIR: ", errors[0]);
        return 1;
    }
    if (ownership_opcode_count(program, string_id, WirOpcode.Retain) != 4 || ownership_opcode_count(program, string_id, WirOpcode.Release) != 3) {
        print("FAIL: String ownership was not balanced");
        return 1;
    }
    if (ownership_opcode_count(program, holder_id, WirOpcode.Retain) != 4 || ownership_opcode_count(program, holder_id, WirOpcode.Release) != 3) {
        print("FAIL: value-struct field ownership was not balanced");
        return 1;
    }
    if (ownership_opcode_count(program, array_id, WirOpcode.Retain) != 8 || ownership_opcode_count(program, array_id, WirOpcode.Release) != 6) {
        print("FAIL: fixed-array element ownership was not balanced");
        return 1;
    }
    if (ownership_opcode_count(program, discard_id, WirOpcode.Retain) != 0 || ownership_opcode_count(program, discard_id, WirOpcode.Release) != 1) {
        print("FAIL: discarded owned call result was not released");
        return 1;
    }
    print("PASS: WIR ownership lowering");
    return 0;
}
