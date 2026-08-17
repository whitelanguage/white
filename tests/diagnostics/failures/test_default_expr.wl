// Test: DEFAULT_PARAMETER_EXPRESSION
// File: tests/diagnostics/failures/test_default_expr.wl
// Focus: Keeping default parameter values independent of the caller's name-resolution context.
// Expected Error: "InvalidSyntax: A default parameter value must be a constant expression."

const DEFAULT_VALUE: Int = 1;

func take(value: Int = DEFAULT_VALUE) -> Void {}

func main() -> Int {
    return 0;
}
