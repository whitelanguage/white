// Test: WIR_CASTS
// File: tests/integration/tooling/test_wir_casts.wl
// Focus: Preserving validated numeric widening in returns and binary expressions.

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

func cast_position() -> Position {
    return Position(idx=0, ln=1, col=1, text="", fn="memory.wl");
}

func cast_token(kind: Int, value: String) -> Token {
    return Token(type=kind, value=value, line=1, col=1);
}

func cast_access(arena: AstArena, name: String, pos: Position) -> NodeID {
    return add_var_access_node(arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=cast_token(TOK_IDENTIFIER, name), pos=pos));
}

func check_return_cast() -> Bool {
    let source: Compiler = Compiler(arena=new_ast_arena(), ptr_base_map=Dict());
    let pos: Position = cast_position();
    let result: NodeID = add_return_node(source.arena, ReturnNode(type=NODE_RETURN, value=cast_access(source.arena, "value", pos), pos=pos));
    let body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[result]));
    let args: Vector(Struct) = [TypeListNode(type=TYPE_INT, pass_mode=PARAM_VALUE)];
    let info: FuncInfo = FuncInfo(name="widen", base_name="widen", ret_type=TYPE_LONG, arg_types=args, arg_names=["value"], is_varargs=false, abi_name="");
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let types: WirTypeMap = new_wir_type_map();
    wir_lower_function_body(ref types, ref source, ref program, info, body);
    if (types.errors.length() != 0) { return false; }
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) { return false; }

    let text: String = print_wir(program)?;
    catch(err) { return false; }
    let expected: String = "internal func @widen(%value:i32) -> i64 {\n^entry:\n    %value.addr:ptr<i32> = alloca i32\n    store %value, %value.addr\n    %3:i32 = load %value.addr\n    %4:i64 = sext %3\n    ret %4\n}\n";
    return text == expected;
}

func check_binary_cast() -> Bool {
    let source: Compiler = Compiler(arena=new_ast_arena(), ptr_base_map=Dict());
    let pos: Position = cast_position();
    let sum: NodeID = add_binop_node(source.arena, BinOpNode(type=NODE_BINOP, left=cast_access(source.arena, "a", pos), op_tok=cast_token(TOK_PLUS, "+"), right=cast_access(source.arena, "b", pos), pos=pos));
    let result: NodeID = add_return_node(source.arena, ReturnNode(type=NODE_RETURN, value=sum, pos=pos));
    let body: NodeID = add_block_node(source.arena, BlockNode(type=NODE_BLOCK, stmts=[result]));
    let args: Vector(Struct) = [TypeListNode(type=TYPE_INT, pass_mode=PARAM_VALUE), TypeListNode(type=TYPE_LONG, pass_mode=PARAM_VALUE)];
    let info: FuncInfo = FuncInfo(name="add_wide", base_name="add_wide", ret_type=TYPE_LONG, arg_types=args, arg_names=["a", "b"], is_varargs=false, abi_name="");
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let types: WirTypeMap = new_wir_type_map();
    wir_lower_function_body(ref types, ref source, ref program, info, body);
    if (types.errors.length() != 0) { return false; }
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) { return false; }

    let text: String = print_wir(program)?;
    catch(err) { return false; }
    let expected: String = "internal func @add_wide(%a:i32, %b:i64) -> i64 {\n^entry:\n    %a.addr:ptr<i32> = alloca i32\n    store %a, %a.addr\n    %b.addr:ptr<i64> = alloca i64\n    store %b, %b.addr\n    %5:i32 = load %a.addr\n    %6:i64 = load %b.addr\n    %7:i64 = sext %5\n    %8:i64 = add %7, %6\n    ret %8\n}\n";
    return text == expected;
}

func cast_result_opcode(program: WirModule, value_id: WirValueID) -> WirOpcode {
    let value: WirValue = program.arena.values[wir_id_index(UInt32(value_id))];
    return program.arena.instructions[wir_id_index(value.owner)].opcode;
}

func check_low_level_casts() -> Bool {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i8: WirTypeID = wir_signed_int_type(ref program, 8);
    let u8: WirTypeID = wir_unsigned_int_type(ref program, 8);
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let u32: WirTypeID = wir_unsigned_int_type(ref program, 32);
    let i64: WirTypeID = wir_signed_int_type(ref program, 64);
    let u64: WirTypeID = wir_unsigned_int_type(ref program, 64);
    let f32: WirTypeID = wir_float_type(ref program, 32);
    let f64: WirTypeID = wir_float_type(ref program, 64);
    let p8: WirTypeID = wir_pointer_type(ref program, u8);
    let p32: WirTypeID = wir_pointer_type(ref program, i32);
    let function_id: WirFuncID = wir_add_function(ref program, "casts", [], program.void_type, false, WirLinkage.Internal, WirABI.White);
    let block: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let signed_value: WirValueID = wir_const_int(ref program, i8, UInt128(1U));
    let unsigned_value: WirValueID = wir_const_int(ref program, u8, UInt128(1U));
    let signed_word: WirValueID = wir_const_int(ref program, i32, UInt128(1U));
    let unsigned_word: WirValueID = wir_const_int(ref program, u32, UInt128(1U));
    let signed_long: WirValueID = wir_const_int(ref program, i64, UInt128(1U));
    let unsigned_long: WirValueID = wir_const_int(ref program, u64, UInt128(1U));
    let narrow_float: WirValueID = wir_const_float(ref program, f32, 1.0);
    let wide_float: WirValueID = wir_const_float(ref program, f64, 1.0);
    let pointer: WirValueID = wir_null(ref program, p8);

    if (cast_result_opcode(program, wir_cast(ref program, block, signed_value, i64, "", no_wir_location())) != WirOpcode.SignExtend) { return false; }
    if (cast_result_opcode(program, wir_cast(ref program, block, unsigned_value, i64, "", no_wir_location())) != WirOpcode.ZeroExtend) { return false; }
    if (cast_result_opcode(program, wir_cast(ref program, block, signed_long, i8, "", no_wir_location())) != WirOpcode.Truncate) { return false; }
    if (cast_result_opcode(program, wir_cast(ref program, block, narrow_float, f64, "", no_wir_location())) != WirOpcode.FloatExtend) { return false; }
    if (cast_result_opcode(program, wir_cast(ref program, block, wide_float, f32, "", no_wir_location())) != WirOpcode.FloatTruncate) { return false; }
    if (cast_result_opcode(program, wir_cast(ref program, block, signed_word, f64, "", no_wir_location())) != WirOpcode.SignedIntToFloat) { return false; }
    if (cast_result_opcode(program, wir_cast(ref program, block, unsigned_word, f64, "", no_wir_location())) != WirOpcode.UnsignedIntToFloat) { return false; }
    if (cast_result_opcode(program, wir_cast(ref program, block, wide_float, i32, "", no_wir_location())) != WirOpcode.FloatToSignedInt) { return false; }
    if (cast_result_opcode(program, wir_cast(ref program, block, wide_float, u32, "", no_wir_location())) != WirOpcode.FloatToUnsignedInt) { return false; }
    if (cast_result_opcode(program, wir_cast(ref program, block, signed_word, u32, "", no_wir_location())) != WirOpcode.Bitcast) { return false; }
    if (cast_result_opcode(program, wir_cast(ref program, block, pointer, p32, "", no_wir_location())) != WirOpcode.Bitcast) { return false; }
    if (cast_result_opcode(program, wir_cast(ref program, block, pointer, u64, "", no_wir_location())) != WirOpcode.PointerToInt) { return false; }
    if (cast_result_opcode(program, wir_cast(ref program, block, unsigned_long, p8, "", no_wir_location())) != WirOpcode.IntToPointer) { return false; }
    wir_return(ref program, block, NO_WIR_VALUE, no_wir_location());
    let errors: Vector(String) = verify_wir(program);
    return errors.length() == 0;
}

func main() -> Int {
    if (!check_return_cast()) {
        print("FAIL: WIR return widening");
        return 1;
    }
    if (!check_binary_cast()) {
        print("FAIL: WIR binary widening");
        return 1;
    }
    if (!check_low_level_casts()) {
        print("FAIL: WIR low-level cast selection");
        return 1;
    }
    print("PASS: WIR casts");
    return 0;
}
