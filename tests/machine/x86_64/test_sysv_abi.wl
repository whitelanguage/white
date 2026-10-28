// Test: X86_64_SYSV_ABI
// File: tests/machine/x86_64/test_sysv_abi.wl
// Focus: Classify scalar and aggregate values into SysV AMD64 eightbytes.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import wir_type_layouts from "../../../src/compiler/wir/layout.wl"
import X86Register from "../../../src/compiler/machine/x86_64/model.wl"
import x86_set_sysv_abi from "../../../src/compiler/machine/x86_64/abi.wl"
import X86SysVCallLayout, x86_plan_sysv_call from "../../../src/compiler/machine/x86_64/abi/sysv.wl"
import X86SysVClass, X86SysVTypeClass, x86_sysv_classify from "../../../src/compiler/abi/sysv.wl"


func expect(actual: X86SysVTypeClass, first: X86SysVClass, second: X86SysVClass, count: Int, size: Int, memory: Bool) -> Bool {
    return actual.first == first && actual.second == second && actual.count == count &&
        actual.size == size && actual.memory == memory;
}

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-unknown-linux-gnu", 64);
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let i64: WirTypeID = wir_signed_int_type(ref program, 64);
    let i128: WirTypeID = wir_signed_int_type(ref program, 128);
    let f32: WirTypeID = wir_float_type(ref program, 32);
    let f64: WirTypeID = wir_float_type(ref program, 64);
    let u8: WirTypeID = wir_unsigned_int_type(ref program, 8);

    let pair: WirTypeID = wir_struct_type(ref program, [i32, i32]);
    let wide_pair: WirTypeID = wir_struct_type(ref program, [i64, i64]);
    let float_pair: WirTypeID = wir_struct_type(ref program, [f64, f64]);
    let mixed: WirTypeID = wir_struct_type(ref program, [f64, i64]);
    let merged: WirTypeID = wir_struct_type(ref program, [f32, i32]);
    let padded: WirTypeID = wir_struct_type(ref program, [u8, f64]);
    let large: WirTypeID = wir_struct_type(ref program, [i64, i64, i64]);
    let float_array: WirTypeID = wir_array_type(ref program, f64, UIntSize(2));
    let layouts: Vector(WirTypeLayout) = wir_type_layouts(program);

    if (!expect(x86_sysv_classify(ref program, pair, layouts), X86SysVClass.Integer, X86SysVClass.Empty, 1, 8, false)) {
        print("FAIL: two i32 fields did not share one INTEGER eightbyte");
        return 1;
    }
    if (!expect(x86_sysv_classify(ref program, wide_pair, layouts), X86SysVClass.Integer, X86SysVClass.Integer, 2, 16, false)) {
        print("FAIL: two i64 fields were not split across integer registers");
        return 1;
    }
    if (!expect(x86_sysv_classify(ref program, float_pair, layouts), X86SysVClass.SSE, X86SysVClass.SSE, 2, 16, false)) {
        print("FAIL: two f64 fields were not split across SSE registers");
        return 1;
    }
    if (!expect(x86_sysv_classify(ref program, mixed, layouts), X86SysVClass.SSE, X86SysVClass.Integer, 2, 16, false)) {
        print("FAIL: mixed aggregate classes are incorrect");
        return 1;
    }
    if (!expect(x86_sysv_classify(ref program, merged, layouts), X86SysVClass.Integer, X86SysVClass.Empty, 1, 8, false)) {
        print("FAIL: INTEGER did not dominate SSE in one eightbyte");
        return 1;
    }
    if (!expect(x86_sysv_classify(ref program, padded, layouts), X86SysVClass.Integer, X86SysVClass.SSE, 2, 16, false)) {
        print("FAIL: padded aggregate classes are incorrect");
        return 1;
    }
    if (!expect(x86_sysv_classify(ref program, float_array, layouts), X86SysVClass.SSE, X86SysVClass.SSE, 2, 16, false)) {
        print("FAIL: array elements were not classified recursively");
        return 1;
    }
    if (!x86_sysv_classify(ref program, large, layouts).memory) {
        print("FAIL: aggregate larger than two eightbytes did not use MEMORY");
        return 1;
    }

    x86_set_sysv_abi(true);
    let mixed_signature: WirTypeID = wir_function_type(ref program, [mixed, wide_pair, float_pair], i32, false, WirABI.C);
    let mixed_layout: X86SysVCallLayout = X86SysVCallLayout(hidden=X86Register.None, arguments=[], stack_size=0);
    x86_plan_sysv_call(
        ref program,
        program.arena.types[wir_id_index(UInt32(mixed_signature))],
        layouts,
        false,
        ref mixed_layout
    );
    if (mixed_layout.arguments[0].first != X86Register.XMM0 || mixed_layout.arguments[0].second != X86Register.RDI ||
        mixed_layout.arguments[1].first != X86Register.RSI || mixed_layout.arguments[1].second != X86Register.RDX ||
        mixed_layout.arguments[2].first != X86Register.XMM1 || mixed_layout.arguments[2].second != X86Register.XMM2 ||
        mixed_layout.stack_size != 0) {
        print("FAIL: mixed register banks were assigned in the wrong order");
        return 1;
    }

    let exhausted_signature: WirTypeID = wir_function_type(ref program, [i64, i64, i64, i64, i64, i64, wide_pair], i32, false, WirABI.C);
    let exhausted: X86SysVCallLayout = X86SysVCallLayout(hidden=X86Register.None, arguments=[], stack_size=0);
    x86_plan_sysv_call(
        ref program,
        program.arena.types[wir_id_index(UInt32(exhausted_signature))],
        layouts,
        false,
        ref exhausted
    );
    if (exhausted.arguments[6].first != X86Register.None || exhausted.arguments[6].second != X86Register.None ||
        exhausted.arguments[6].stack_offset != 0 || exhausted.arguments[6].stack_size != 16 || exhausted.stack_size != 16) {
        print("FAIL: exhausted register bank did not move the complete aggregate to the stack");
        return 1;
    }

    let aligned_signature: WirTypeID = wir_function_type(ref program, [i64, i64, i64, i64, i64, i64, i64, i128], i32, false, WirABI.C);
    let aligned: X86SysVCallLayout = X86SysVCallLayout(hidden=X86Register.None, arguments=[], stack_size=0);
    x86_plan_sysv_call(
        ref program,
        program.arena.types[wir_id_index(UInt32(aligned_signature))],
        layouts,
        false,
        ref aligned
    );
    if (aligned.arguments[6].stack_offset != 0 || aligned.arguments[7].stack_offset != 16 || aligned.stack_size != 32) {
        print("FAIL: 16-byte stack argument alignment is incorrect");
        return 1;
    }

    print("PASS: x86_64 SysV ABI classification");
    return 0;
}
