// Test: DUPLICATE_LOCAL
// File: tests/diagnostics/failures/test_duplicate_local.wl
// Focus: Rejecting two declarations of the same name in one scope.
// Expected Error: "NameError: Variable 'value' is already declared in this scope"

func main() -> Int { let value: Int = 1; let value: Int = 2; return value; }
