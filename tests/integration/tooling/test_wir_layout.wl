// Test: WIR_LAYOUT
// File: tests/integration/tooling/test_wir_layout.wl
// Focus: Computing target sizes, alignments, and field offsets without relying on LLVM.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/layout.wl"

func check_target(target: String, pointer_bits: Int, i64_alignment: Int, i128_alignment: Int, f64_alignment: Int, stack_alignment: Int, record_size: UInt64, record_alignment: Int, wide_offset: UInt64, pointer_offset: UInt64, string_size: UInt64) -> Bool {
    let program: WirModule = new_wir_module(target, pointer_bits);
    if (!program.data_layout.valid || program.data_layout.pointer_bits != pointer_bits ||
        program.data_layout.i64_alignment != i64_alignment || program.data_layout.i128_alignment != i128_alignment ||
        program.data_layout.f64_alignment != f64_alignment || program.data_layout.stack_alignment != stack_alignment) {
        print("FAIL: target data layout does not match ", target);
        return false;
    }

    let u8_type: WirTypeID = wir_unsigned_int_type(ref program, 8);
    let i32_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let i64_type: WirTypeID = wir_signed_int_type(ref program, 64);
    let i128_type: WirTypeID = wir_signed_int_type(ref program, 128);
    let f64_type: WirTypeID = wir_float_type(ref program, 64);
    let pointer_type: WirTypeID = wir_pointer_type(ref program, u8_type);
    let record_type: WirTypeID = wir_struct_type(ref program, [u8_type, i64_type, pointer_type]);
    let string_type: WirTypeID = wir_struct_type(ref program, [pointer_type, i32_type, i32_type]);
    let array_type: WirTypeID = wir_array_type(ref program, string_type, UIntSize(3U));

    let record: WirTypeLayout = wir_type_layout(program, record_type);
    let string: WirTypeLayout = wir_type_layout(program, string_type);
    let array: WirTypeLayout = wir_type_layout(program, array_type);
    if (!record.valid || record.size != record_size || record.alignment != record_alignment || record.field_offsets.length() != 3 ||
        record.field_offsets[0] != 0UL || record.field_offsets[1] != wide_offset || record.field_offsets[2] != pointer_offset) {
        print("FAIL: record layout does not match ", target);
        return false;
    }
    if (!string.valid || string.size != string_size || array.size != string_size * 3UL ||
        wir_type_alignment(program, i128_type) != i128_alignment || wir_type_alignment(program, f64_type) != f64_alignment) {
        print("FAIL: scalar or array layout does not match ", target);
        return false;
    }
    return true;
}

func main() -> Int {
    if (!check_target("i686-pc-windows-msvc", 32, 8, 16, 8, 4, 24UL, 8, 8UL, 16UL, 12UL)) { return 1; }
    if (!check_target("i686-unknown-linux-gnu", 32, 4, 16, 4, 16, 16UL, 4, 4UL, 12UL, 12UL)) { return 1; }
    if (!check_target("armv7-unknown-linux-gnueabihf", 32, 8, 8, 8, 8, 24UL, 8, 8UL, 16UL, 12UL)) { return 1; }
    if (!check_target("x86_64-pc-windows-msvc", 64, 8, 16, 8, 16, 24UL, 8, 8UL, 16UL, 16UL)) { return 1; }
    if (!check_target("x86_64-unknown-linux-gnu", 64, 8, 16, 8, 16, 24UL, 8, 8UL, 16UL, 16UL)) { return 1; }
    if (!check_target("aarch64-unknown-linux-gnu", 64, 8, 16, 8, 16, 24UL, 8, 8UL, 16UL, 16UL)) { return 1; }
    if (!check_target("x86_64-apple-darwin", 64, 8, 16, 8, 16, 24UL, 8, 8UL, 16UL, 16UL)) { return 1; }
    if (!check_target("arm64-apple-darwin", 64, 8, 16, 8, 16, 24UL, 8, 8UL, 16UL, 16UL)) { return 1; }
    print("PASS: WIR target data layouts");
    return 0;
}
