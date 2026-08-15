// Test: POW_FUNCTIONALITY
// File: tests/language/basics/test_pow_operator.wl
// Focus: Power operator (**) precedence, calculation accuracy, and right-associativity.

func close(left: Float, right: Float, tolerance: Float) -> Bool {
    let difference: Float = left - right;
    if (difference < 0.0) { difference = -difference; }
    return difference <= tolerance;
}

func main() -> Int {
    let a: Int = 2;
    let b: Int = 3;

    // 2^3 = 8
    if (a ** b == 8) {
        print("PASS: Basic power calculation");
    } else {
        print("FAIL: Power calculation error");
    }

    // right-associativity test: 2 ** (3 ** 2) = 2 ** 9 = 512
    if (2 ** 3 ** 2 == 512) {
        print("PASS: Power operator associativity");
    } else {
        print("FAIL: Power operator associativity");
        return 1;
    }

    let base: Float = 9.0;
    let half: Float = 0.5;
    let root: Float = base ** half;
    let inverse: Float = 2.0 ** -3.0;
    let signed: Float = (-2.0) ** 3.0;
    let invalid: Float = (-2.0) ** half;
    if (!close(root, 3.0, 0.000000000001) || !close(inverse, 0.125, 0.000000000001) || signed != -8.0 || invalid == invalid) {
        print("FAIL: Dynamic power edge cases");
        return 1;
    }
    print("PASS: Dynamic power edge cases");
    
    return 0;
}
