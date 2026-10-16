// Test: POINTER_VALUE_NOT_EQUAL
// File: tests/diagnostics/failures/test_pointer_value_not_equal.wl
// Focus: Typed pointer addresses use is !, not value inequality.
// Expected Error: "TypeError: Pointer addresses must be compared with 'is' or 'is !'."

func main() -> Int {
    let value: Int = 1;
    let ptr pointer: Int = ref value;
    let different: Bool = pointer != pointer;
    return 0;
}
