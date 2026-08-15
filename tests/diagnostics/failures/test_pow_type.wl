// Test: POW_OPERAND_TYPE
// File: tests/diagnostics/failures/test_pow_type.wl
// Focus: Requiring numeric operands for exponentiation.
// Expected Error: "TypeError: Operator '**' requires numeric operands"

func main() -> Int { let value: Float = true ** 2; return 0; }
