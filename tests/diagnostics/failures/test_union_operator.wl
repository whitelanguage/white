// Test: UNION_OPERATOR
// File: tests/diagnostics/failures/test_union_operator.wl
// Focus: Rejecting arithmetic on a union before selecting a concrete member.
// Expected Error: "TypeError: Invalid types for binary operator."

func main() -> Int {
    let value: Optional(Int) = 1;
    let result = value + 1;
    return 0;
}
