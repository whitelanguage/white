// Test: FLOAT_REMAINDER
// File: tests/language/basics/test_float_mod.wl
// Focus: Floating-point remainder without a platform math library.


func remainder(left: Float, right: Float) -> Float {
    return left % right;
}

func remainder32(left: Float32, right: Float32) -> Float32 {
    return left % right;
}

func main() -> Int {
    if (remainder(5.5, 2.0) != 1.5 || remainder(-5.5, 2.0) != -1.5 || remainder(5.5, -2.0) != 1.5 || remainder32(5.5f, 2.0f) != 1.5f) {
        print("FAIL: floating-point remainder");
        return 1;
    }
    print("PASS: floating-point remainder");
    return 0;
}
