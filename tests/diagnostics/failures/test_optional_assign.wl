// Test: OPTIONAL_ASSIGN
// File: tests/diagnostics/failures/test_optional_assign.wl
// Focus: A reassignment invalidates a local type check.
// Expected Error: "TypeError: Type mismatch. Expected Int, got (Null | Int)."

func main() -> Int {
    let value: Optional(Int) = 42;
    if (value is null) { return 0; }
    value = null;
    return value;
}
