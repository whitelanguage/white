// Test: UNION_BIT_NOT
// File: tests/diagnostics/failures/test_union_bit_not.wl
// Focus: Bitwise complement requires a concrete integer operand.
// Expected Error: "TypeError: Operator '~' requires an integer type."

func main() -> Int {
    let value: Optional(Int) = 1;
    let result = ~value;
    return 0;
}
