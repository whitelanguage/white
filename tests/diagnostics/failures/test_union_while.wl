// Test: UNION_WHILE
// File: tests/diagnostics/failures/test_union_while.wl
// Focus: A loop condition requires Bool rather than an unchecked Optional Bool.
// Expected Error: "TypeError: While condition must be a Bool."

func main() -> Int {
    let value: Optional(Bool) = false;
    while value { break; }
    return 0;
}
