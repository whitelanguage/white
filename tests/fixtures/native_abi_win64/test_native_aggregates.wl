// Test: NATIVE_AGGREGATES
// File: tests/fixtures/native_abi_win64/test_native_aggregates.wl
// Target: x86_64-pc-windows-msvc
// Focus: C aggregate parameters and returns, exports, and callable adapters.
// Link: native_aggregates.c
import "../native_aggregates.wl" as native


func main() -> Int {
    if (native.native_one(native.NativeOne(Byte(20))).value != Byte(21)) { return 1; }
    if (native.native_two(native.NativeTwo(Int16(400))).value != Int16(402)) { return 2; }
    if (native.native_float(native.NativeFloat(1.5f)).value != 2.0f) { return 3; }
    let eight = native.native_eight(native.NativeEight(10, 20));
    if (eight.left != 13 || eight.right != 24) { return 4; }
    let bytes: Byte[3] = [Byte(1), Byte(2), Byte(3)];
    let three = native.native_three(native.NativeThree(bytes));
    if (three.values[0] != Byte(1) || three.values[1] != Byte(7) || three.values[2] != Byte(3)) { return 5; }
    let twelve = native.native_twelve(native.NativeTwelve(10, 20, 30));
    if (twelve.middle != 26) { return 6; }
    let original = native.NativeLarge(100L, 200L, 300L);
    let large = native.native_large(1, 2.0, original, 3, 4.0);
    if (large.left != 104L || large.middle != 200L || large.right != 306L || original.left != 100L) { return 7; }

    let text = "aggregate " + String(42);
    let pair = native.native_pair(text);
    if (pair.left != text || pair.right != text) { return 8; }
    let make_pair = native.native_pair;
    if (make_pair(text).right != text) { return 9; }
    let make_exported = native.exported_pair;
    if (make_exported(text).right != text) { return 15; }
    let small = native.native_float;
    if (small(native.NativeFloat(1.5f)).value != 2.0f) { return 10; }
    let make_large = native.native_large;
    if (make_large(1, 2.0, original, 3, 4.0).right != 306L) { return 11; }
    let exported = native.exported_large;
    if (exported(1, 2.0, original, 3, 4.0).left != 104L) { return 12; }
    if (native.native_aggregate_entries() != 0) { return 13; }
    let system = native.native_system_large;
    if (system(1, 2.0, original, 3, 4.0).left != 104L) { return 17; }

    let i = 0;
    while (i < 2000) {
        if (make_large(1, 2.0, original, 3, 4.0).left != 104L) { return 14; }
        i++;
    }
    print("PASS: native aggregate ABI");
    return 0;
}
