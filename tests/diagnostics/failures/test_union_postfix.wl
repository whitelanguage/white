// Test: UNION_POSTFIX
// File: tests/diagnostics/failures/test_union_postfix.wl
// Focus: Postfix mutation cannot operate on a union carrier.
// Expected Error: "TypeError: Cannot increment/decrement type (Null | Int)"

func main() -> Int {
    let value: Optional(Int) = 1;
    value++;
    return 0;
}
