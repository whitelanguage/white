// Test: STATIC_SEMANTIC_TYPES
// File: tests/language/basics/test_semantic_types.wl
// Focus: Numeric widening, named calls, NaN comparison, and top-level Auto.

const INFERRED: Auto = 9;

func subtract(left: Int, right: Int) -> Int { return left - right; }

func spin() -> Int { for (;;) { } }

func main() -> Int {
    let signed_small: Int8 = 12;
    let signed_wide: Int128 = signed_small;
    let unsigned_small: Byte = 4;
    let unsigned_wide: UInt64 = unsigned_small;
    let narrow_float: Float32 = 1.5;
    let wide_float: Float = narrow_float;
    let nan: Float = (-1.0) ** 0.5;
    if (signed_wide != 12LL || unsigned_wide != 4UL || wide_float != 1.5) { print("FAIL: numeric widening"); return 1; }
    if (subtract(right=3, left=10) != 7 || INFERRED != 9) { print("FAIL: named arguments or top-level Auto"); return 1; }
    if (!(nan != nan)) { print("FAIL: NaN inequality"); return 1; }
    print("PASS: static semantic types");
    return 0;
}
