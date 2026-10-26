// Test: LOGIC_RHS
// File: tests/diagnostics/failures/test_logic_rhs.wl
// Focus: The right operand of a short-circuit expression must match the Bool left operand.
// Expected Error: "TypeError: Both logic operands must have type Bool."

func main() -> Int {
    let value: Optional(Bool) = true;
    let result = false || value;
    return 0;
}
