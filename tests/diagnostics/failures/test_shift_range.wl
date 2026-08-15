// Test: SHIFT_RANGE
// File: tests/diagnostics/failures/test_shift_range.wl
// Focus: Rejecting constant shift counts outside the operand width.
// Expected Error: "OverflowError: Shift count must be between 0 and 31"

func main() -> Int { let value: Int = 1 << 32; return value; }
