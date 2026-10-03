// Test: LONG_IMMEDIATE_ARITHMETIC
// File: tests/language/types/test_long_immediate.wl
// Focus: 64-bit arithmetic and comparisons lowered with sign-extended immediates.

func calculate(value: Long) -> Long {
    let result = 7L + value;
    result = 3L * result;
    result -= 5L;
    result ^= 8L;
    result |= 8L;
    result &= 255L;
    return result;
}

func main() -> Int {
    let value = calculate(40L);
    if (value != 136L || value < 128L || value > 255L) {
        print("FAIL: Long immediate arithmetic");
        return 1;
    }
    print("PASS: Long immediate arithmetic");
    return 0;
}
