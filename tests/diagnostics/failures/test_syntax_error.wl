// Test: SYNTAX_INCOMPLETE_EXPRESSION
// File: tests/diagnostics/failures/test_syntax_error.wl
// Focus: Error reporting for unclosed parentheses and incomplete expressions.
// Expected Error: "InvalidSyntax: Expected ')'."

func main() -> Int {
    // Intentional syntax error: missing closing parenthesis
    let x: Int = (1 + 2; 
    return 0;
}
