// Test: WIR_MODEL
// File: tests/integration/tooling/test_wir.wl
// Focus: WIR IDs, control flow and verifier checks remain consistent.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/verify.wl"
import * from "../../../src/compiler/wir/print.wl"

func has_wir_error(errors: Vector(String), message: String) -> Bool {
    let i: Int = 0;
    while (i < errors.length()) {
        if (errors[i] == message) { return true; }
        i++;
    }
    return false;
}

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    if (wir_signed_int_type(ref program, 32) != int_type) {
        print("FAIL: scalar types were not interned");
        return 1;
    }

    let node_type: WirTypeID = wir_declare_struct(ref program, "Node");
    let node_pointer: WirTypeID = wir_pointer_type(ref program, node_type);
    wir_define_struct(ref program, node_type, [int_type, node_pointer]);
    let zero: WirValueID = wir_const_int(ref program, int_type, UInt128(0U));
    let forty_two: WirValueID = wir_const_int(ref program, int_type, UInt128(42U));
    let scratch: WirGlobalID = wir_add_global(ref program, "scratch", int_type, zero, WirLinkage.Private, false);
    wir_add_global(ref program, "count", int_type, zero, WirLinkage.Internal, false);
    wir_add_global(ref program, "answer", int_type, forty_two, WirLinkage.Exported, true);
    wir_add_global(ref program, "errno", int_type, NO_WIR_VALUE, WirLinkage.External, false);
    if (wir_global_value(program, scratch) != program.arena.globals[wir_id_index(UInt32(scratch))].address) {
        print("FAIL: global address was not stable");
        return 1;
    }

    let byte_type: WirTypeID = wir_unsigned_int_type(ref program, 8);
    let size_type: WirTypeID = wir_unsigned_int_type(ref program, 64);
    let byte_pointer: WirTypeID = wir_pointer_type(ref program, byte_type);
    wir_add_function(ref program, "write", [wir_param("", int_type), wir_param("", byte_pointer), wir_param("", size_type)], wir_signed_int_type(ref program, 64), false, WirLinkage.External, WirABI.C);
    wir_add_function(ref program, "printf", [wir_param("", byte_pointer)], int_type, true, WirLinkage.External, WirABI.C);
    wir_add_function(ref program, "GetStdHandle", [wir_param("", int_type)], wir_pointer_type(ref program, program.void_type), false, WirLinkage.External, WirABI.System);
    let function_id: WirFuncID = wir_add_function(ref program, "add", [wir_param("a", int_type), wir_param("b", int_type)], int_type, false, WirLinkage.Internal, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let exit: WirBlockID = wir_add_block(ref program, function_id, "exit", [wir_param("value", int_type)]);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    if (wir_function_value(program, function_id) != function.address) {
        print("FAIL: function address was not stable");
        return 1;
    }
    let sum: WirValueID = wir_append(ref program, entry, WirOpcode.Add, int_type, [function.parameters[0], function.parameters[1]], [], no_wir_location());
    wir_name_value(ref program, sum, "sum");
    wir_append(ref program, entry, WirOpcode.Jump, program.void_type, [], [wir_edge(exit, [sum])], no_wir_location());
    let exit_block: WirBlock = program.arena.blocks[wir_id_index(UInt32(exit))];
    wir_append(ref program, exit, WirOpcode.Return, program.void_type, [exit_block.parameters[0]], [], no_wir_location());

    let float_type: WirTypeID = wir_float_type(ref program, 64);
    let encoded_one: WirValueID = wir_const_float(ref program, float_type, 1.0);
    if (program.arena.values[wir_id_index(UInt32(encoded_one))].float_bits != UInt64(4607182418800017408)) {
        print("FAIL: f64 constant did not preserve its IEEE representation");
        return 1;
    }
    let float_function: WirFuncID = wir_add_function(ref program, "one", [], float_type, false, WirLinkage.Exported, WirABI.White);
    let float_entry: WirBlockID = wir_add_block(ref program, float_function, "entry", []);
    let one: WirValueID = wir_const_float_bits(ref program, float_type, UInt64(4607182418800017408));
    wir_append(ref program, float_entry, WirOpcode.Return, program.void_type, [one], [], no_wir_location());

    let long_type: WirTypeID = wir_signed_int_type(ref program, 64);
    let int_pointer: WirTypeID = wir_pointer_type(ref program, int_type);
    let exercise: WirFuncID = wir_add_function(ref program, "exercise", [wir_param("value", int_type), wir_param("address", int_pointer)], long_type, false, WirLinkage.Private, WirABI.White);
    let exercise_entry: WirBlockID = wir_add_block(ref program, exercise, "entry", []);
    let exercise_then: WirBlockID = wir_add_block(ref program, exercise, "then", []);
    let exercise_trap: WirBlockID = wir_add_block(ref program, exercise, "trap", []);
    let exercise_exit: WirBlockID = wir_add_block(ref program, exercise, "exit", [wir_param("result", long_type)]);
    let exercise_info: WirFunction = program.arena.functions[wir_id_index(UInt32(exercise))];
    let slot: WirValueID = wir_append(ref program, exercise_entry, WirOpcode.StackAlloc, int_pointer, [], [], no_wir_location());
    wir_name_value(ref program, slot, "slot");
    wir_append(ref program, exercise_entry, WirOpcode.Store, program.void_type, [exercise_info.parameters[0], slot], [], no_wir_location());
    let loaded: WirValueID = wir_append(ref program, exercise_entry, WirOpcode.Load, int_type, [slot], [], no_wir_location());
    wir_name_value(ref program, loaded, "loaded");
    let limit: WirValueID = wir_const_int(ref program, int_type, UInt128(10U));
    let less: WirValueID = wir_append(ref program, exercise_entry, WirOpcode.SignedLess, program.bool_type, [loaded, limit], [], no_wir_location());
    wir_name_value(ref program, less, "less");
    wir_append(ref program, exercise_entry, WirOpcode.NullCheck, program.void_type, [exercise_info.parameters[1]], [], no_wir_location());
    wir_append(ref program, exercise_entry, WirOpcode.BoundsCheck, program.void_type, [loaded, limit], [], no_wir_location());
    wir_append(ref program, exercise_entry, WirOpcode.Branch, program.void_type, [less], [wir_edge(exercise_then, []), wir_edge(exercise_trap, [])], no_wir_location());

    let increment_value: WirValueID = wir_const_int(ref program, int_type, UInt128(1U));
    let increment: WirValueID = wir_append(ref program, exercise_then, WirOpcode.Call, int_type, [wir_function_value(program, function_id), loaded, increment_value], [], no_wir_location());
    wir_name_value(ref program, increment, "increment");
    let wide: WirValueID = wir_append(ref program, exercise_then, WirOpcode.SignExtend, long_type, [increment], [], no_wir_location());
    wir_name_value(ref program, wide, "wide");
    wir_retain(ref program, exercise_then, exercise_info.parameters[1], no_wir_location());
    wir_release(ref program, exercise_then, exercise_info.parameters[1], no_wir_location());
    wir_append(ref program, exercise_then, WirOpcode.Jump, program.void_type, [], [wir_edge(exercise_exit, [wide])], no_wir_location());
    wir_append(ref program, exercise_trap, WirOpcode.Unreachable, program.void_type, [], [], no_wir_location());
    let exercise_exit_info: WirBlock = program.arena.blocks[wir_id_index(UInt32(exercise_exit))];
    wir_append(ref program, exercise_exit, WirOpcode.Return, program.void_type, [exercise_exit_info.parameters[0]], [], no_wir_location());

    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: valid WIR was rejected: ", errors[0]);
        return 1;
    }

    let text: String = print_wir(program)?;
    catch(err) {
        print("FAIL: valid WIR could not be printed");
        return 1;
    }
    let expected: String = "type !Node = {i32, ptr<!Node>}\n\nglobal @scratch:i32 = 0\ninternal global @count:i32 = 0\npub const @answer:i32 = 42\nextern global @errno:i32\n\nextern c func @write(i32, ptr<u8>, u64) -> i64\n\nextern c func @printf(ptr<u8>, ...) -> i32\n\nextern system func @GetStdHandle(i32) -> ptr<void>\n\ninternal func @add(%a:i32, %b:i32) -> i32 {\n^entry:\n    %sum:i32 = add %a, %b\n    jmp ^exit(%sum)\n\n^exit(%value:i32):\n    ret %value\n}\n\npub func @one() -> f64 {\n^entry:\n    ret f64(0x3FF0000000000000)\n}\n\nfunc @exercise(%value:i32, %address:ptr<i32>) -> i64 {\n^entry:\n    %slot:ptr<i32> = alloca i32\n    store %value, %slot\n    %loaded:i32 = load %slot\n    %less:bool = slt %loaded, 10\n    check.null %address\n    check.bounds %loaded, 10\n    br %less, ^then(), ^trap()\n\n^then:\n    %increment:i32 = call @add(%loaded, 1)\n    %wide:i64 = sext %increment\n    retain %address\n    release %address\n    jmp ^exit(%wide)\n\n^trap:\n    unreachable\n\n^exit(%result:i64):\n    ret %result\n}\n";
    if (text != expected) {
        print("FAIL: WIR text is not stable");
        print(text);
        return 1;
    }

    let invalid: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let invalid_int: WirTypeID = wir_signed_int_type(ref invalid, 32);
    let invalid_function: WirFuncID = wir_add_function(ref invalid, "broken", [], invalid_int, false, WirLinkage.Internal, WirABI.White);
    wir_add_block(ref invalid, invalid_function, "entry", []);
    let invalid_errors: Vector(String) = verify_wir(invalid);
    if (invalid_errors.length() == 0) {
        print("FAIL: unterminated WIR block was accepted");
        return 1;
    }

    let invalid_global: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let invalid_global_type: WirTypeID = wir_signed_int_type(ref invalid_global, 32);
    let invalid_initializer: WirValueID = wir_const_int(ref invalid_global, invalid_global_type, UInt128(1U));
    wir_add_global(ref invalid_global, "foreign", invalid_global_type, invalid_initializer, WirLinkage.External, false);
    let invalid_global_errors: Vector(String) = verify_wir(invalid_global);
    if (!has_wir_error(invalid_global_errors, "external global has an initializer")) {
        print("FAIL: initialized external global was accepted");
        return 1;
    }

    let duplicate: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let duplicate_type: WirTypeID = wir_signed_int_type(ref duplicate, 32);
    let duplicate_value: WirValueID = wir_const_int(ref duplicate, duplicate_type, UInt128(0U));
    wir_add_global(ref duplicate, "same", duplicate_type, duplicate_value, WirLinkage.Internal, false);
    wir_add_function(ref duplicate, "same", [], duplicate_type, false, WirLinkage.External, WirABI.C);
    let duplicate_errors: Vector(String) = verify_wir(duplicate);
    if (!has_wir_error(duplicate_errors, "symbol is defined more than once")) {
        print("FAIL: duplicate WIR symbol was accepted");
        return 1;
    }

    print("PASS: WIR model and verifier");
    return 0;
}
