// Test: AARCH64_CASTS
// File: tests/machine/aarch64/test_casts.wl
// Focus: Preserve integer bits across pointer casts and equal-width bitcasts.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import verify_wir from "../../../src/compiler/wir/verify.wl"
import A64Object from "../../../src/compiler/machine/aarch64/model.wl"
import * from "../../../src/compiler/machine/aarch64/lowering.wl"
import A64ModuleResult from "../../../src/compiler/machine/aarch64/model.wl"
import a64_lower_module from "../../../src/compiler/machine/aarch64/module.wl"
import * from "../../../src/compiler/machine/aarch64/elf.wl"


func main() -> Int {
    let program: WirModule = new_wir_module("aarch64-unknown-linux-gnu", 64);
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let i64: WirTypeID = wir_signed_int_type(ref program, 64);
    let i128: WirTypeID = wir_signed_int_type(ref program, 128);
    let u64: WirTypeID = wir_unsigned_int_type(ref program, 64);
    let u128: WirTypeID = wir_unsigned_int_type(ref program, 128);
    let f32: WirTypeID = wir_float_type(ref program, 32);
    let f64: WirTypeID = wir_float_type(ref program, 64);
    let pointer: WirTypeID = wir_pointer_type(ref program, wir_unsigned_int_type(ref program, 8));

    let function: WirFuncID = wir_add_function(ref program, "pointer_casts", [WirParam(name="value", type_id=i32)], i64, false, WirLinkage.Exported, WirABI.C);
    let block: WirBlockID = wir_add_block(ref program, function, "entry", []);
    let value: WirValueID = program.arena.functions[wir_id_index(UInt32(function))].parameters[0];
    let address: WirValueID = wir_cast(ref program, block, value, pointer, "address", no_wir_location());
    let bits: WirValueID = wir_cast(ref program, block, address, u64, "bits", no_wir_location());
    let signed_bits: WirValueID = wir_cast(ref program, block, bits, i64, "signed_bits", no_wir_location());
    wir_return(ref program, block, signed_bits, no_wir_location());

    let wide: WirFuncID = wir_add_function(ref program, "wide_pointer_casts", [WirParam(name="address", type_id=pointer)], pointer, false, WirLinkage.Exported, WirABI.C);
    let wide_block: WirBlockID = wir_add_block(ref program, wide, "entry", []);
    let wide_address: WirValueID = program.arena.functions[wir_id_index(UInt32(wide))].parameters[0];
    let wide_bits: WirValueID = wir_cast(ref program, wide_block, wide_address, u128, "wide_bits", no_wir_location());
    let restored: WirValueID = wir_cast(ref program, wide_block, wide_bits, pointer, "restored", no_wir_location());
    wir_return(ref program, wide_block, restored, no_wir_location());

    let local: WirFuncID = wir_add_function(ref program, "local_pointer_cast", [], u64, false, WirLinkage.Exported, WirABI.C);
    let local_block: WirBlockID = wir_add_block(ref program, local, "entry", []);
    let local_slot: WirValueID = wir_stack_alloc(ref program, local_block, i64, "slot", no_wir_location());
    let local_bits: WirValueID = wir_cast(ref program, local_block, local_slot, u64, "bits", no_wir_location());
    wir_return(ref program, local_block, local_bits, no_wir_location());

    let wide_bitcast: WirFuncID = wir_add_function(ref program, "wide_bitcast", [WirParam(name="value", type_id=u128)], i128, false, WirLinkage.Exported, WirABI.C);
    let wide_bitcast_block: WirBlockID = wir_add_block(ref program, wide_bitcast, "entry", []);
    let wide_bitcast_value: WirValueID = program.arena.functions[wir_id_index(UInt32(wide_bitcast))].parameters[0];
    let signed_wide: WirValueID = wir_cast(ref program, wide_bitcast_block, wide_bitcast_value, i128, "signed", no_wir_location());
    wir_return(ref program, wide_bitcast_block, signed_wide, no_wir_location());

    let float_bits: WirFuncID = wir_add_function(ref program, "float_bits", [WirParam(name="value", type_id=f64)], i64, false, WirLinkage.Exported, WirABI.C);
    let float_bits_block: WirBlockID = wir_add_block(ref program, float_bits, "entry", []);
    let float_value: WirValueID = program.arena.functions[wir_id_index(UInt32(float_bits))].parameters[0];
    let float_raw: WirValueID = wir_unary(ref program, float_bits_block, WirOpcode.Bitcast, i64, float_value, "raw", no_wir_location());
    wir_return(ref program, float_bits_block, float_raw, no_wir_location());

    let bits_float: WirFuncID = wir_add_function(ref program, "bits_float", [WirParam(name="value", type_id=i64)], f64, false, WirLinkage.Exported, WirABI.C);
    let bits_float_block: WirBlockID = wir_add_block(ref program, bits_float, "entry", []);
    let raw_value: WirValueID = program.arena.functions[wir_id_index(UInt32(bits_float))].parameters[0];
    let restored_float: WirValueID = wir_unary(ref program, bits_float_block, WirOpcode.Bitcast, f64, raw_value, "value", no_wir_location());
    wir_return(ref program, bits_float_block, restored_float, no_wir_location());

    let single_bits: WirFuncID = wir_add_function(ref program, "single_bits", [WirParam(name="value", type_id=f32)], i32, false, WirLinkage.Exported, WirABI.C);
    let single_bits_block: WirBlockID = wir_add_block(ref program, single_bits, "entry", []);
    let single_value: WirValueID = program.arena.functions[wir_id_index(UInt32(single_bits))].parameters[0];
    let single_raw: WirValueID = wir_unary(ref program, single_bits_block, WirOpcode.Bitcast, i32, single_value, "raw", no_wir_location());
    wir_return(ref program, single_bits_block, single_raw, no_wir_location());

    let bool_extend: WirFuncID = wir_add_function(ref program, "bool_extend", [], u64, false, WirLinkage.Exported, WirABI.C);
    let bool_extend_block: WirBlockID = wir_add_block(ref program, bool_extend, "entry", []);
    let bool_value: WirValueID = wir_const_bool(ref program, true);
    let bool_wide: WirValueID = wir_unary(ref program, bool_extend_block, WirOpcode.ZeroExtend, u64, bool_value, "wide", no_wir_location());
    wir_return(ref program, bool_extend_block, bool_wide, no_wir_location());

    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: invalid AArch64 cast test: ", errors[0]);
        return 1;
    }

    let lowered: A64ModuleResult = a64_lower_module(ref program);
    if (lowered.errors.length() != 0) {
        print("FAIL: AArch64 cast lowering: ", lowered.errors[0]);
        return 1;
    }

    let object: Vector(Byte) = a64_elf_object(A64Object(sections=lowered.sections, symbols=lowered.symbols, relocations=lowered.relocations))?;
    catch(err) {
        print("FAIL: AArch64 cast ELF output");
        return 1;
    }
    if (object.length() == 0) {
        print("FAIL: empty AArch64 cast object");
        return 1;
    }

    print("PASS: AArch64 pointer casts");
    return 0;
}
