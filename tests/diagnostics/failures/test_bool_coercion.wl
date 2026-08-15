// Test: BOOL_COERCION
// File: tests/diagnostics/failures/test_bool_coercion.wl
// Focus: Keeping Bool separate from integer types.
// Expected Error: "TypeError: Type mismatch"

func main() -> Int { let value: Int = true; return value; }
