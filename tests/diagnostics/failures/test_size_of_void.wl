// Test: SIZE_OF_VOID
// File: tests/diagnostics/failures/test_size_of_void.wl
// Focus: Rejecting layout queries for a type with no value representation.
// Expected Error: "TypeError: Type 'Void' has no size."

func main() -> Int {
    let value: UIntSize = size_of(Void);
    return Int(value);
}
