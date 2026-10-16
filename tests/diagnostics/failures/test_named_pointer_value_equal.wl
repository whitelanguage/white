// Test: NAMED_POINTER_VALUE_EQUAL
// File: tests/diagnostics/failures/test_named_pointer_value_equal.wl
// Focus: A distinct pointer type still uses address identity.
// Expected Error: "TypeError: Pointer addresses must be compared with 'is' or 'is !'."

type Address = AnyPtr;

func main() -> Int {
    let value: Int = 1;
    let pointer: Address = Address(ref value);
    let same: Bool = pointer == pointer;
    return 0;
}
