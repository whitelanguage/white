// Test: CLASS_FIELD_UNINITIALIZED
// File: tests/diagnostics/failures/test_field_uninit.wl
// Focus: Rejecting a class field that no constructor initializes.
// Expected Error: "MissingInitializer: Field 'value' has no initializer, but class 'Missing' does not define init."

class Missing {
    let value: Int;
}

func main() -> Int {
    return 0;
}
