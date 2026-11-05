// Test: FALLIBLE_RETURN_NEGATIVE
// File: tests/diagnostics/failures/test_fallible_return_negative.wl
// Focus: An unsigned success type must reject a negative literal.
// Expected Error: "OverflowError: Constant -1 overflows UInt64"

func convert() -> UInt64? {
    return -1;
}

func main() -> Int {
    return 0;
}
