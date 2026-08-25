// Test: WIR_VERIFIER
// File: tests/integration/tooling/test_wir_verifier.wl
// Focus: Rejecting malformed low-level types, casts, and stack placement.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/verify.wl"

func verifier_has(errors: Vector(String), expected: String) -> Bool {
    let i: Int = 0;
    while (i < errors.length()) {
        if (errors[i] == expected) { return true; }
        i++;
    }
    return false;
}

func rejects_recursive_layout() -> Bool {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let recursive: WirTypeID = wir_declare_struct(ref program, "Recursive");
    wir_define_struct(ref program, recursive, [recursive]);
    let errors: Vector(String) = verify_wir(program);
    return verifier_has(errors, "aggregate type contains itself by value");
}

func rejects_late_alloca() -> Bool {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let function_id: WirFuncID = wir_add_function(ref program, "late_alloca", [], i32_type, false, WirLinkage.Internal, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let body: WirBlockID = wir_add_block(ref program, function_id, "body", []);
    wir_append(ref program, entry, WirOpcode.Jump, program.void_type, [], [wir_edge(body, [])], no_wir_location());
    wir_stack_alloc(ref program, body, i32_type, "late", no_wir_location());
    wir_return(ref program, body, wir_const_int(ref program, i32_type, UInt128(0U)), no_wir_location());
    let errors: Vector(String) = verify_wir(program);
    return verifier_has(errors, "stack allocation is outside the function entry block");
}

func rejects_wrong_cast_opcode() -> Bool {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i8_type: WirTypeID = wir_signed_int_type(ref program, 8);
    let i64_type: WirTypeID = wir_signed_int_type(ref program, 64);
    let function_id: WirFuncID = wir_add_function(ref program, "wrong_cast", [], i64_type, false, WirLinkage.Internal, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let value: WirValueID = wir_const_int(ref program, i8_type, UInt128(1U));
    let result: WirValueID = wir_append(ref program, entry, WirOpcode.ZeroExtend, i64_type, [value], [], no_wir_location());
    wir_return(ref program, entry, result, no_wir_location());
    let errors: Vector(String) = verify_wir(program);
    return verifier_has(errors, "cast opcode does not match its source and target types");
}

func rejects_cross_function_value() -> Bool {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let first_id: WirFuncID = wir_add_function(ref program, "first", [wir_param("value", i32_type)], i32_type, false, WirLinkage.Internal, WirABI.White);
    let first_entry: WirBlockID = wir_add_block(ref program, first_id, "entry", []);
    let first: WirFunction = program.arena.functions[wir_id_index(UInt32(first_id))];
    wir_return(ref program, first_entry, first.parameters[0], no_wir_location());

    let second_id: WirFuncID = wir_add_function(ref program, "second", [], i32_type, false, WirLinkage.Internal, WirABI.White);
    let second_entry: WirBlockID = wir_add_block(ref program, second_id, "entry", []);
    wir_return(ref program, second_entry, first.parameters[0], no_wir_location());
    let errors: Vector(String) = verify_wir(program);
    return verifier_has(errors, "instruction uses a value outside its SSA scope");
}

func rejects_non_dominating_value() -> Bool {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let function_id: WirFuncID = wir_add_function(ref program, "branches", [], i32_type, false, WirLinkage.Internal, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let left: WirBlockID = wir_add_block(ref program, function_id, "left", []);
    let right: WirBlockID = wir_add_block(ref program, function_id, "right", []);
    wir_append(ref program, entry, WirOpcode.Branch, program.void_type, [wir_const_bool(ref program, true)], [wir_edge(left, []), wir_edge(right, [])], no_wir_location());
    let one: WirValueID = wir_const_int(ref program, i32_type, UInt128(1U));
    let left_value: WirValueID = wir_binary(ref program, left, WirOpcode.Add, i32_type, one, one, "left_value", no_wir_location());
    wir_return(ref program, left, left_value, no_wir_location());
    wir_return(ref program, right, left_value, no_wir_location());
    let errors: Vector(String) = verify_wir(program);
    return verifier_has(errors, "instruction uses a value outside its SSA scope");
}

func main() -> Int {
    if (!rejects_recursive_layout()) { print("FAIL: recursive WIR layout was accepted"); return 1; }
    if (!rejects_late_alloca()) { print("FAIL: late WIR stack allocation was accepted"); return 1; }
    if (!rejects_wrong_cast_opcode()) { print("FAIL: mismatched WIR cast opcode was accepted"); return 1; }
    if (!rejects_cross_function_value()) { print("FAIL: cross-function WIR value was accepted"); return 1; }
    if (!rejects_non_dominating_value()) { print("FAIL: non-dominating WIR value was accepted"); return 1; }
    print("PASS: WIR verifier invariants");
    return 0;
}
