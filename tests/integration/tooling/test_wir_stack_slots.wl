// Test: WIR_STACK_SLOTS
// File: tests/integration/tooling/test_wir_stack_slots.wl
// Focus: Hoisting loop-local storage to the function entry block.

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

func stack_slot_token(kind: Int, value: String) -> Token {
    return Token(type=kind, value=value, line=1, col=1);
}

func main() -> Int {
    let source: Compiler = Compiler(arena=new_ast_arena(), ptr_base_map=Dict());
    let pos: Position = Position(idx=0, ln=1, col=1, text="", fn="memory.wl");
    let condition: NodeID = add_var_access_node(source.arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=stack_slot_token(TOK_IDENTIFIER, "flag"), pos=pos));
    let one: NodeID = add_int_node(source.arena, IntNode(type=NODE_INT, tok=stack_slot_token(TOK_INT, "1"), pos=pos));
    let local: NodeID = add_var_decl_node(source.arena, VarDeclareNode(type=NODE_VAR_DECL, name_tok=stack_slot_token(TOK_IDENTIFIER, "value"), type_node=NO_NODE, value=one, is_const=false, annotations=[], pos=pos, alloc_id=0));
    let stop: NodeID = add_break_node(source.arena, BreakNode(type=NODE_BREAK, pos=pos));
    let loop_body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[local, stop]));
    let loop: NodeID = add_while_node(source.arena, WhileNode(type=NODE_WHILE, condition=condition, body=loop_body, pos=pos));
    let zero: NodeID = add_int_node(source.arena, IntNode(type=NODE_INT, tok=stack_slot_token(TOK_INT, "0"), pos=pos));
    let result: NodeID = add_return_node(source.arena, ReturnNode(type=NODE_RETURN, value=zero, pos=pos));
    let body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[loop, result]));

    let info: FuncInfo = FuncInfo(name="stack_slots", base_name="stack_slots", ret_type=TYPE_INT, arg_types=[TypeListNode(type=TYPE_BOOL, pass_mode=PARAM_VALUE)], arg_names=["flag"], is_varargs=false, abi_name="");
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let types: WirTypeMap = new_wir_type_map();
    let function_id: WirFuncID = wir_lower_function_body(ref types, ref source, ref program, info, body);
    if (types.errors.length() != 0) {
        print("FAIL: loop-local storage was rejected: ", types.errors[0]);
        return 1;
    }
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: loop-local storage produced invalid WIR: ", errors[0]);
        return 1;
    }

    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let i: Int = 0;
    while (i < function.blocks.length()) {
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(function.blocks[i]))];
        let j: Int = 0;
        while (j < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[j]))];
            if (instruction.opcode == WirOpcode.StackAlloc && function.blocks[i] != function.entry) {
                print("FAIL: loop-local storage remained inside the loop");
                return 1;
            }
            j++;
        }
        i++;
    }
    print("PASS: WIR stack slots");
    return 0;
}
