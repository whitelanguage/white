// Test: NULLPTR_VALUE_EQUAL
// File: tests/diagnostics/failures/test_nullptr_value_equal.wl
// Focus: Null pointer identity uses the same rule in each lowering path.
// Expected Error: "TypeError: Invalid operator. Do not use '==' or '!=' with null/nullptr. Use 'is' or 'is !'."

func main() -> Int {
    let same: Bool = nullptr == nullptr;
    return 0;
}
