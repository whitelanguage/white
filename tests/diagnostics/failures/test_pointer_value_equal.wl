// Test: POINTER_VALUE_EQUAL
// File: tests/diagnostics/failures/test_pointer_value_equal.wl
// Focus: Typed pointer addresses use is, not value equality.
// Expected Error: "TypeError: Pointer addresses must be compared with 'is' or 'is !'."

func main() -> Int {
    let value: Int = 1;
    let ptr pointer: Int = ref value;
    let same: Bool = pointer == pointer;
    return 0;
}
