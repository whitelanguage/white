// Test: UNKNOWN_VALUE_PARAMETER
// File: tests/diagnostics/failures/test_unknown_value_param.wl
// Focus: Reporting an unknown value parameter type before symbol mangling.
// Expected Error: "TypeError: Unknown type: User"

func replace(target: User) -> Void {
    target = User("Bob");
}
