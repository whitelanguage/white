// Test: UNARY_PLUS
// File: tests/diagnostics/failures/test_unary_plus.wl
// Focus: Unary plus cannot silently accept non-numeric values.
// Expected Error: "TypeError: Operator '+' requires a numeric type."

func main() -> Int {
    let result = +"text";
    return 0;
}
