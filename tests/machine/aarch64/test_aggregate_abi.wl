// Test: AARCH64_AGGREGATE_ABI
// File: tests/machine/aarch64/test_aggregate_abi.wl
// Focus: Pass and return integer aggregates and HFAs through the AAPCS64 register convention.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import verify_wir from "../../../src/compiler/wir/verify.wl"
import wir_type_layouts from "../../../src/compiler/wir/layout.wl"
import * from "../../../src/compiler/machine/aarch64/lowering.wl"
import a64_hfa_type, A64HFA from "../../../src/compiler/machine/aarch64/abi.wl"
import A64ModuleResult from "../../../src/compiler/machine/aarch64/model.wl"
import a64_lower_module from "../../../src/compiler/machine/aarch64/module.wl"


func add_echo(ref program: WirModule, name: String, type_id: WirTypeID) -> WirFuncID {
    let function_id: WirFuncID = wir_add_function(ref program, name, [wir_param("value", type_id)], type_id, false, WirLinkage.Internal, WirABI.C);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    wir_return(ref program, entry, function.parameters[0], no_wir_location());

    return function_id;
}

func add_relay(ref program: WirModule, name: String, type_id: WirTypeID, echo: WirFuncID) -> Void {
    let function_id: WirFuncID = wir_add_function(ref program, name, [wir_param("value", type_id)], type_id, false, WirLinkage.Exported, WirABI.C);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let result: WirValueID = wir_call(
        ref program,
        entry,
        program.arena.functions[wir_id_index(UInt32(echo))].address,
        [function.parameters[0]],
        "result",
        no_wir_location()
    );
    wir_return(ref program, entry, result, no_wir_location());
}

func main() -> Int {
    let program: WirModule = new_wir_module("aarch64-unknown-linux-gnu", 64);
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let i64: WirTypeID = wir_signed_int_type(ref program, 64);
    let f64: WirTypeID = wir_float_type(ref program, 64);
    let small: WirTypeID = wir_struct_type(ref program, [i64, i32]);
    let large: WirTypeID = wir_struct_type(ref program, [i64, i64, i64]);
    let hfa: WirTypeID = wir_struct_type(ref program, [f64, f64, f64]);

    let small_echo: WirFuncID = add_echo(ref program, "small_echo", small);
    let large_echo: WirFuncID = add_echo(ref program, "large_echo", large);
    let hfa_echo: WirFuncID = add_echo(ref program, "hfa_echo", hfa);
    add_relay(ref program, "round_small", small, small_echo);
    add_relay(ref program, "round_large", large, large_echo);
    add_relay(ref program, "round_hfa", hfa, hfa_echo);

    let tail_params: Vector(WirParam) = [];
    let i: Int = 0;
    while (i < 8) {
        tail_params.append(wir_param("prefix" + i, i64));
        i++;
    }
    tail_params.append(wir_param("value", small));
    let tail_id: WirFuncID = wir_add_function(ref program, "tail_small", tail_params, i32, false, WirLinkage.Internal, WirABI.C);
    let tail_entry: WirBlockID = wir_add_block(ref program, tail_id, "entry", []);
    let tail_function: WirFunction = program.arena.functions[wir_id_index(UInt32(tail_id))];
    wir_return(ref program, tail_entry, wir_field(ref program, tail_entry, tail_function.parameters[8], 1, "value", no_wir_location()), no_wir_location());

    let tail_caller: WirFuncID = wir_add_function(ref program, "call_tail_small", [], i32, false, WirLinkage.Exported, WirABI.C);
    let tail_caller_entry: WirBlockID = wir_add_block(ref program, tail_caller, "entry", []);
    let tail_args: Vector(WirValueID) = [];
    i = 0;
    while (i < 8) {
        tail_args.append(wir_const_int(ref program, i64, UInt128(i)));
        i++;
    }
    tail_args.append(wir_struct_value(ref program, tail_caller_entry, small, [wir_const_int(ref program, i64, UInt128(11U)), wir_const_int(ref program, i32, UInt128(42U))], "pair", no_wir_location()));
    let tail_result: WirValueID = wir_call(ref program, tail_caller_entry, program.arena.functions[wir_id_index(UInt32(tail_id))].address, tail_args, "result", no_wir_location());
    wir_return(ref program, tail_caller_entry, tail_result, no_wir_location());

    let zero_id: WirFuncID = wir_add_function(ref program, "zero_small", [], small, false, WirLinkage.Exported, WirABI.C);
    let zero_entry: WirBlockID = wir_add_block(ref program, zero_id, "entry", []);
    wir_return(ref program, zero_entry, wir_const_zero(ref program, small), no_wir_location());

    let constant_id: WirFuncID = wir_add_function(ref program, "constant_small", [], small, false, WirLinkage.Exported, WirABI.C);
    let constant_entry: WirBlockID = wir_add_block(ref program, constant_id, "entry", []);
    let constant_small: WirValueID = wir_const_aggregate(ref program, small, [wir_const_int(ref program, i64, UInt128(11U)), wir_const_int(ref program, i32, UInt128(42U))]);
    wir_return(ref program, constant_entry, constant_small, no_wir_location());

    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: invalid AArch64 aggregate ABI test: ", errors[0]);
        return 1;
    }

    let layouts: Vector(WirTypeLayout) = wir_type_layouts(program);
    let hfa_info: A64HFA = a64_hfa_type(ref program, hfa, layouts);
    if (!hfa_info.valid || hfa_info.bits != 64 || hfa_info.count != 3) {
        print("FAIL: AArch64 HFA classification is incorrect");
        return 1;
    }

    let lowered: A64ModuleResult = a64_lower_module(ref program);
    if (lowered.errors.length() != 0) {
        print("FAIL: AArch64 aggregate ABI lowering: ", lowered.errors[0]);
        return 1;
    }
    if (lowered.symbols.length() != 10 || lowered.relocations.length() != 4 ||
        lowered.sections.length() == 0 || lowered.sections[0].bytes.length() == 0) {
        print("FAIL: AArch64 aggregate ABI output is incomplete");
        return 1;
    }

    print("PASS: AArch64 aggregate calling convention");
    return 0;
}
