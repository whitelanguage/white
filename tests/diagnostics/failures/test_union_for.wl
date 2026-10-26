// Test: UNION_FOR
// File: tests/diagnostics/failures/test_union_for.wl
// Focus: A for condition requires Bool rather than a union value.
// Expected Error: "TypeError: For condition must be a Bool."

func main() -> Int {
    let value: Optional(Bool) = false;
    for (let i = 0; value; i++) { break; }
    return 0;
}
