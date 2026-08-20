// Test: UNKNOWN_POINTER_PARAMETER
// File: tests/diagnostics/failures/test_unknown_ptr_param.wl
// Focus: Reporting an unknown pointer parameter type before symbol mangling.
// Expected Error: "TypeError: Unknown type: User"

func replace(ptr target: User) -> Void {
    target = User("Bob");
}
