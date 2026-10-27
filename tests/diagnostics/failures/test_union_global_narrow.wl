// Test: UNION_GLOBAL_NARROW
// File: tests/diagnostics/failures/test_union_global_narrow.wl
// Focus: The active constant member does not permit implicit union narrowing.
// Expected Error: "Type mismatch. Expected"

const value: Int | String | Null = "text";
const copy: Optional(String) = value;

func main() -> Int {
    return 0;
}
