// Test: ANYPTR_VALUE_EQUAL
// File: tests/diagnostics/failures/test_anyptr_value_equal.wl
// Focus: Erasing a pointer type does not enable value equality.
// Expected Error: "TypeError: Pointer addresses must be compared with 'is' or 'is !'."

func main() -> Int {
    let value: Int = 1;
    let pointer: AnyPtr = ref value;
    let same = pointer == pointer;
    return 0;
}
