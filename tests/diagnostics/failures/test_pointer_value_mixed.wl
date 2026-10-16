// Test: POINTER_VALUE_MIXED
// File: tests/diagnostics/failures/test_pointer_value_mixed.wl
// Focus: Comparing a raw pointer with an integer stays a source type error.
// Expected Error: "TypeError: Pointer addresses must be compared with 'is' or 'is !'."

func main() -> Int {
    let value: Int = 1;
    let pointer: AnyPtr = ref value;
    let same: Bool = pointer == 1;
    return 0;
}
