// Test: NULL_VALUE
// File: tests/diagnostics/failures/test_null_value.wl
// Focus: Null admits only null, regardless of its backend storage representation.
// Expected Error: "TypeError: Type mismatch. Expected Null, got Int"

func main() -> Int {
    let value: Null = 1;
    return 0;
}
