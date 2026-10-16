// Test: ANYPTR_VALUE_NOT_EQUAL
// File: tests/diagnostics/failures/test_anyptr_value_not_equal.wl
// Focus: AnyPtr inequality cannot bypass the identity operators.
// Expected Error: "TypeError: Pointer addresses must be compared with 'is' or 'is !'."

func main() -> Int {
    let value: Int = 1;
    let pointer: AnyPtr = ref value;
    let different = pointer != pointer;
    return 0;
}
