// Test: WIR_STORAGE
// File: tests/integration/tooling/test_wir_storage.wl
// Focus: Static storage offsets, symbolic relocations, padding and malformed constants.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import verify_wir from "../../../src/compiler/wir/verify.wl"
import print_wir from "../../../src/compiler/wir/print.wl"
import emit_wir_llvm from "../../../src/compiler/wir/backend/llvm.wl"


func main() -> Int {
    let program = new_wir_module("x86_64-pc-windows-msvc", 64);
    let u8 = wir_unsigned_int_type(ref program, 8);
    let u32 = wir_unsigned_int_type(ref program, 32);
    let u128 = wir_unsigned_int_type(ref program, 128);
    let data = wir_const_bytes(ref program, wir_array_type(ref program, u8, UIntSize(2U)), "a\0");
    let global = wir_add_global(ref program, "data", wir_value_type(ref program, data), data, WirLinkage.Private, true);
    let address = wir_const_address(ref program, wir_pointer_type(ref program, u8), wir_global_value(ref program, global), 0L);
    let type = wir_struct_type(ref program, [u32, u128]);
    let tag = wir_const_int(ref program, u32, UInt128(1U));
    let value = wir_const_storage(ref program, type, [tag, address, address], [0UL, 16UL, 24UL]);
    wir_add_global(ref program, "storage", type, value, WirLinkage.Exported, true);
    if (verify_wir(program).length() != 0) { return 1; }
    let text = print_wir(program)?;
    catch(err) { return 2; }
    let emitted = emit_wir_llvm(program)?;
    catch(err) { return 3; }
    if (emitted.errors.length() != 0 || !text.ends_with("storage { 0: u32 1, 16: ptr<u8> addr @data, 24: ptr<u8> addr @data }\n")) { return 4; }

    let constant = program.arena.values[wir_id_index(UInt32(value))];
    program.arena.constants[wir_id_index(constant.owner)].offsets = [0UL, 16UL, 20UL];
    if (verify_wir(program).length() == 0) { return 5; }
    program.arena.constants[wir_id_index(constant.owner)].offsets = [0UL, 16UL, 32UL];
    if (verify_wir(program).length() == 0) { return 6; }
    program.arena.constants[wir_id_index(constant.owner)].offsets = [0UL];
    if (verify_wir(program).length() == 0) { return 7; }
    program.arena.constants[wir_id_index(constant.owner)].offsets = [0UL, 16UL, 24UL];
    let function = wir_add_function(ref program, "invalid", [], type, false, WirLinkage.Internal, WirABI.White);
    let entry = wir_add_block(ref program, function, "entry", []);
    wir_return(ref program, entry, value, no_wir_location());
    if (verify_wir(program).length() == 0) { return 8; }
    print("PASS: WIR static storage");
    return 0;
}
