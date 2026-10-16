// Test: NULLPTR_VALUE_NOT_EQUAL
// File: tests/diagnostics/failures/test_nullptr_value_not_equal.wl
// Focus: Null pointer inequality uses is ! in every backend.
// Expected Error: "TypeError: Invalid operator. Do not use '==' or '!=' with null/nullptr. Use 'is' or 'is !'."

func main() -> Int {
    let different: Bool = nullptr != nullptr;
    return 0;
}
