// Test: UNION_NEGATE
// File: tests/diagnostics/failures/test_union_negate.wl
// Focus: Rejecting negation before an Optional value has been checked.
// Expected Error: "TypeError: Cannot negate non-numeric type."

func main() -> Int {
    let value: Optional(Int) = 1;
    let result = -value;
    return 0;
}
