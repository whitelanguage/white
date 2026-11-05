// Test: FALLIBLE_RETURN_OVERFLOW
// File: tests/diagnostics/failures/test_fallible_return_overflow.wl
// Focus: A narrow success type must reject an out-of-range literal.
// Expected Error: "OverflowError: Constant 300 overflows Byte"

func convert() -> Byte? {
    return 300;
}

func main() -> Int {
    return 0;
}
