// Test: NULL_POINTER
// File: tests/diagnostics/failures/test_null_pointer.wl
// Focus: A null pointer literal does not belong to the Null value type.
// Expected Error: "TypeError: 'nullptr' can only be assigned to explicit pointer types."

func main() -> Int {
    let value: Null = nullptr;
    return 0;
}
