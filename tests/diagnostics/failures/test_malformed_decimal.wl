// Test: MALFORMED_DECIMAL_LITERAL
// File: tests/diagnostics/failures/test_malformed_decimal.wl
// Focus: A malformed decimal expression must be rejected before code generation.
// Expected Error: "InvalidSyntax: Expected field name after '.'."

func main() -> Int {
    let value: Float = 1.2.3;
    return Int(value);
}
