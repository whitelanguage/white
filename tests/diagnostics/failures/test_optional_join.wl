// Test: OPTIONAL_JOIN
// File: tests/diagnostics/failures/test_optional_join.wl
// Focus: A branch join retains only checks true on every surviving path.
// Expected Error: "TypeError: Type mismatch. Expected Int, got (Null | Int)."

func main() -> Int {
    let value: Optional(Int) = 42;
    if (value is null) { return 0; }
    if (value is !null) { value = null; }
    return value;
}
