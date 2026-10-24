// Test: NULL_SLICE
// File: tests/diagnostics/failures/test_null_slice.wl
// Focus: An ordinary Array slice needs a valid owner, absence uses Optional.
// Expected Error: "TypeError: Type Int[-1] cannot be null."

func main() -> Int {
    let values: Array(Int) = null;
    return 0;
}
