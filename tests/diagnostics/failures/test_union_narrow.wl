// Test: UNION_NARROW
// File: tests/diagnostics/failures/test_union_narrow.wl
// Focus: A wider union cannot be assigned to one which drops a possible member.
// Expected Error: "TypeError: Type mismatch. Expected (Null | Int), got (Null | String | Int)."

func main() -> Int {
    let wide: Int | String | Null = "text";
    let narrow: Optional(Int) = wide;
    return 0;
}
