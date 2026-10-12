// Test: AARCH64_CASTS
// File: tests/machine/aarch64/test_casts.wl
// Focus: Preserve integer bits across pointer casts and equal-width bitcasts.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import verify_wir from "../../../src/compiler/wir/verify.wl"
import A64Object from "../../../src/compiler/machine/aarch64/model.wl"
import * from "../../../src/compiler/machine/aarch64/lowering.wl"
import * from "../../../src/compiler/machine/aarch64/elf.wl"


func main() -> Int {
    let program: WirModule = new_wir_module("aarch64-unknown-linux-gnu", 64);
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let i64: WirTypeID = wir_signed_int_type(ref program, 64);
    let u64: WirTypeID = wir_unsigned_int_type(ref program, 64);
    let u128: WirTypeID = wir_unsigned_int_type(ref program, 128);
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
