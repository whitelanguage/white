// Test: UNION_NOT
// File: tests/diagnostics/failures/test_union_not.wl
// Focus: Optional Bool cannot act as Bool before narrowing.
// Expected Error: "TypeError: Operator '!' requires Bool type."

func main() -> Int {
    let value: Optional(Bool) = true;
    let result = !value;
    return 0;
}
