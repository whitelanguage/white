// tests/fixtures/native_aggregates.wl
struct NativeOne(value: Byte)
struct NativeTwo(value: Int16)
struct NativeFloat(value: Float32)
struct NativeEight(left: Int, right: Int)
struct NativeThree(values: Byte[3])
struct NativeTwelve(left: Int, middle: Int, right: Int)
struct NativeLarge(left: Long, middle: Long, right: Long)
struct NativePair(left: String, right: String)

extern "C" {
    func native_one(value: NativeOne) -> NativeOne;
    func native_two(value: NativeTwo) -> NativeTwo;
    func native_float(value: NativeFloat) -> NativeFloat;
    func native_eight(value: NativeEight) -> NativeEight;
    func native_three(value: NativeThree) -> NativeThree;
    func native_twelve(value: NativeTwelve) -> NativeTwelve;
    func native_large(a: Int, b: Float, value: NativeLarge, c: Int, d: Float) -> NativeLarge;
    func native_pair(text: String) -> NativePair;
    func native_pair_null(text: String) -> NativePair;
    func native_aggregate_entries() -> Int;
}

extern "system" {
    func native_system_large(a: Int, b: Float, value: NativeLarge, c: Int, d: Float) -> NativeLarge;
}

@ExportLib
func exported_one(value: NativeOne) -> NativeOne { return value; }

@ExportLib
func exported_two(value: NativeTwo) -> NativeTwo { return value; }

@ExportLib
func exported_float(value: NativeFloat) -> NativeFloat { return value; }

@ExportLib
func exported_eight(value: NativeEight) -> NativeEight { return value; }

@ExportLib
func exported_three(value: NativeThree) -> NativeThree { return value; }

@ExportLib
func exported_twelve(value: NativeTwelve) -> NativeTwelve { return value; }

@ExportLib
func exported_large(a: Int, b: Float, value: NativeLarge, c: Int, d: Float) -> NativeLarge {
    value.left += Long(a + c);
    value.right += Long(b + d);
    return value;
}

@ExportLib
func exported_pair(text: String) -> NativePair {
    return NativePair(text, text);
}
