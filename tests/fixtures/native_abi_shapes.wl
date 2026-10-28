// tests/fixtures/native_abi_shapes.wl
// Link: native_abi_shapes.c
struct NativeF2(a: Float32, b: Float32)
struct NativeF3(a: Float32, b: Float32, c: Float32)
struct NativeD4(a: Float, b: Float, c: Float, d: Float)
struct NativeMixed(a: Float32, b: Long)
struct NativeI3(a: Int, b: Int, c: Int)
struct NativeWide(value: Int128)
struct NativeEmpty()
let EMPTY_TAIL: Int = 0;

extern "C" {
    func native_f2(v: NativeF2) -> NativeF2;
    func native_f3(v: NativeF3) -> NativeF3;
    func native_d4(v: NativeD4) -> NativeD4;
    func native_mixed(v: NativeMixed) -> NativeMixed;
    func native_gp_pressure(a: Int, b: Int, c: Int, d: Int, e: Int, v: NativeI3, f: Int) -> NativeI3;
    func native_fp_pressure(a: Float, b: Float, c: Float, d: Float, e: Float, f: Float, g: Float, h: Float, v: NativeMixed, tail: Int) -> NativeMixed;
    func native_hfa_stack(a: Float, b: Float, c: Float, d: Float, e: Float, f: Float, g: Float, h: Float, v: NativeF3, tail: Int) -> NativeF3;
    func native_wide(value: Int128) -> Int128;
    func native_wide_pressure(a: Int, b: Int, c: Int, d: Int, e: Int, value: Int128, tail: Int) -> Int128;
    func native_wide_record(v: NativeWide) -> NativeWide;
    func native_narrow(value: Int8) -> Int8;
    func native_empty(value: NativeEmpty, tail: Int) -> NativeEmpty;
    func native_shape_exports() -> Int;
}

@ExportLib
func exported_f2(v: NativeF2) -> NativeF2 { return v; }
@ExportLib
func exported_f3(v: NativeF3) -> NativeF3 { return v; }
@ExportLib
func exported_d4(v: NativeD4) -> NativeD4 { return v; }
@ExportLib
func exported_mixed(v: NativeMixed) -> NativeMixed { return v; }
@ExportLib
func exported_gp_pressure(a: Int, b: Int, c: Int, d: Int, e: Int, v: NativeI3, f: Int) -> NativeI3 {
    v.c += a + b + c + d + e + f;
    return v;
}
@ExportLib
func exported_fp_pressure(a: Float, b: Float, c: Float, d: Float, e: Float, f: Float, g: Float, h: Float, v: NativeMixed, tail: Int) -> NativeMixed {
    v.b += Long(a + b + c + d + e + f + g + h) + Long(tail);
    return v;
}
@ExportLib
func exported_hfa_stack(a: Float, b: Float, c: Float, d: Float, e: Float, f: Float, g: Float, h: Float, v: NativeF3, tail: Int) -> NativeF3 {
    v.c += Float32(a + b + c + d + e + f + g + h) + Float32(tail);
    return v;
}
@ExportLib
func exported_wide(value: Int128) -> Int128 { return value; }
@ExportLib
func exported_wide_pressure(a: Int, b: Int, c: Int, d: Int, e: Int, value: Int128, tail: Int) -> Int128 {
    return value + Int128(a + b + c + d + e + tail);
}
@ExportLib
func exported_wide_record(v: NativeWide) -> NativeWide { return v; }
@ExportLib
func exported_narrow(value: Int8) -> Int { return Int(value); }
@ExportLib
func exported_empty(value: NativeEmpty, tail: Int) -> NativeEmpty {
    EMPTY_TAIL = tail;
    return value;
}

func main() -> Int {
    if (native_f2(NativeF2(1.0f, 2.0f)).b != 4.0f) { return 1; }
    if (native_f3(NativeF3(1.0f, 2.0f, 3.0f)).c != 6.0f) { return 2; }
    if (native_d4(NativeD4(1.0, 2.0, 3.0, 4.0)).d != 8.0) { return 3; }
    if (native_mixed(NativeMixed(1.5f, 20L)).b != 25L) { return 4; }
    if (native_gp_pressure(1, 2, 3, 4, 5, NativeI3(10, 20, 30), 6).c != 51) { return 5; }
    if (native_fp_pressure(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, NativeMixed(1.5f, 20L), 9).b != 65L) { return 6; }
    if (native_hfa_stack(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, NativeF3(1.0f, 2.0f, 3.0f), 9).c != 48.0f) { return 7; }
    let big = (Int128(1) << Int128(100)) + Int128(7);
    if (native_wide(big) != big + Int128(3)) { return 8; }
    if (native_wide_pressure(1, 2, 3, 4, 5, big, 6) != big + Int128(21)) { return 15; }
    if (native_wide_record(NativeWide(big)).value != big + Int128(7)) { return 9; }
    if (native_narrow(Int8(-11)) != Int8(-12)) { return 10; }
    if (size_of(NativeEmpty) != UIntSize(1)) { return 14; }
    let empty = native_empty(NativeEmpty(), 19);
    let fn_f3 = native_f3;
    if (fn_f3(NativeF3(1.0f, 2.0f, 3.0f)).c != 6.0f) { return 11; }
    let fn_export = exported_d4;
    if (fn_export(NativeD4(1.0, 2.0, 3.0, 4.0)).d != 4.0) { return 12; }
    let exports = native_shape_exports();
    if (exports != 0 || EMPTY_TAIL != 17) {
        print("FAIL: exported native shape", exports);
        return 13;
    }
    print("PASS: native aggregate classes and register pressure");
    return 0;
}
