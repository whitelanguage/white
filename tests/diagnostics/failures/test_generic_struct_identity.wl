// Test: GENERIC_STRUCT_IDENTITY
// File: tests/diagnostics/failures/test_generic_struct_identity.wl
// Focus: Generic Struct instances remain values in an identity comparison.
// Expected Error: "TypeError: Operator 'is' is not defined for Struct values. Compare explicit pointers instead."

struct Box<T>(value: T)

func main() -> Int {
    let box: Box(Int) = Box(1);
    let same: Bool = box is box;
    return 0;
}
