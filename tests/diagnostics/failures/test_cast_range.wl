// Test: CAST_RANGE
// File: tests/diagnostics/failures/test_cast_range.wl
// Focus: A constant cast must be rejected when the value does not fit the target type.
// Expected Error: "OverflowError: Constant 256 overflows Byte"

func main() -> Int {
    let value: Byte = Byte(256);
    return Int(value);
}
