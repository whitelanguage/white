// Test: UNION_IF
// File: tests/diagnostics/failures/test_union_if.wl
// Focus: A union carrier cannot serve as an if condition.
// Expected Error: "TypeError: If condition must be a Bool."

func main() -> Int {
    let value: Optional(Bool) = true;
    if value { return 1; }
    return 0;
}
