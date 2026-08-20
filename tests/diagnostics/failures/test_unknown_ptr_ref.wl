// Test: UNKNOWN_POINTER_REFERENCE
// File: tests/diagnostics/failures/test_unknown_ptr_ref.wl
// Focus: Reporting an unknown pointer type without lowering a reference expression.
// Expected Error: "TypeError: Unknown type: User"

func replace(ptr target: User) -> Void {
    target = ref User("Bob");
}
