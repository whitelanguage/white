// Test: FOR_SCOPE
// File: tests/diagnostics/failures/test_for_scope.wl
// Focus: Keeping the initializer variable inside the for statement.
// Expected Error: "NameError: Undefined variable or function 'index'."

func main() -> Int { for (let index: Int = 0; index < 1; index += 1) { } return index; }
