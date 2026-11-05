// Test: FALLIBLE_RETURN_SIGNED
// File: tests/diagnostics/failures/test_fallible_return_signed.wl
// Focus: Return context must not turn a signed variable into an unsigned value.
// Expected Error: "TypeError: Type mismatch. Expected UInt64, got Int"

func convert(value: Int) -> UInt64? {
    return value;
}

func main() -> Int {
    return 0;
}
