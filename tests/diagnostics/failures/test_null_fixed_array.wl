// Test: NULL_FIXED_ARRAY
// File: tests/diagnostics/failures/test_null_fixed_array.wl
// Focus: Null cannot initialize an inline fixed array.
// Expected Error: "InvalidSyntax: Expected ')' after Array type."

func main() -> Int {
    let values: Array(Int, 2) = null;
    return values[0];
}
