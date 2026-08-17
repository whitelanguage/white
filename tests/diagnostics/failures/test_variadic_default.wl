// Test: VARIADIC_DEFAULT
// File: tests/diagnostics/failures/test_variadic_default.wl
// Focus: Rejecting a default value on the variadic parameter itself.
// Expected Error: "InvalidSyntax: A variadic parameter cannot have a default value."

func take(values: Int... = 1) -> Void {}

func main() -> Int {
    return 0;
}
