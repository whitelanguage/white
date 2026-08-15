// Test: COMPLEX_ARITHMETIC
// File: tests/language/basics/test_arithmetic.wl
// Focus: Deeply nested parentheses and operator precedence.

func main() -> Int {
    let res: Float = (2.0 + 3.0) * 5.0 / 3.0 + (6.0 - 3.0 / 78.0) + 114.0 * 514.0;

    if (res > 58609.000000 && res < 58611.000000) {
        print("PASS: Complex arithmetic precision");
    } else {
        print("FAIL: Arithmetic mismatch, got: " + res);
    }
    return 0;
}
