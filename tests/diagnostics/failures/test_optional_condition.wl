// Test: OPTIONAL_CONDITION
// File: tests/diagnostics/failures/test_optional_condition.wl
// Focus: A later call in a compound condition invalidates an earlier global check.
// Expected Error: "TypeError: Type mismatch. Expected Int, got (Null | Int)."

let value: Optional(Int) = 42;
func reset() -> Bool { value = null; return true; }
func main() -> Int {
    if (value is !null && reset()) { return value; }
    return 0;
}
