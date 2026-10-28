// tests/fixtures/native_varargs.wl
// Link: native_varargs.c
struct VaRecord(a: Int, b: Int, c: Int)

extern "C" {
    func native_va_pairs(prefix: Float32, count: Int, ...) -> Float;
    func native_va_record(value: VaRecord, count: Int, ...) -> VaRecord;
    func native_va_pointer(expected: Int, ...) -> Int;
    func native_va_wide(count: Int, ...) -> Int;
}

func main() -> Int {
    let result = native_va_pairs(0.5f, 2, Int8(-2), 1.25f, UInt16(20), 2.5f);
    if (result != 22.25) { return 1; }
    let many = native_va_pairs(0.5f, 10, 1, 1.0, 2, 2.0, 3, 3.0, 4, 4.0, 5, 5.0, 6, 6.0, 7, 7.0, 8, 8.0, 9, 9.0, 10, 10.0);
    if (many != 110.5) { return 2; }
    let record = native_va_record(VaRecord(10, 20, 30), 2, true, 2.0f, Byte(5), 3.0f);
    if (record.a != 10 || record.b != 26 || record.c != 35) { return 3; }
    let value = 42;
    if (native_va_pointer(42, ref value) != 1) { return 4; }
    let wide = (Int128(1) << Int128(100)) + Int128(7);
    if (native_va_wide(1, wide) != 1) { return 5; }
    print("PASS: native variadic promotions and register overflow");
    return 0;
}
