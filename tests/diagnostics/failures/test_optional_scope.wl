// Test: OPTIONAL_SCOPE
// File: tests/diagnostics/failures/test_optional_scope.wl
// Focus: Checks on shadowing block locals cannot narrow an outer binding.
// Expected Error: "TypeError: Type mismatch. Expected Int, got (Null | Int)."

func main() -> Int {
    let value: Optional(Int) = null;
    let flag = true;
    if flag {
        let value: Optional(Int) = 4;
        if (value is null) { return 1; }
    } else {
        let value: Optional(Int) = 5;
        if (value is null) { return 1; }
    }
    return value;
}
