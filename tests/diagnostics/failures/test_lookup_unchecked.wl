// Test: LOOKUP_UNCHECKED
// File: tests/diagnostics/failures/test_lookup_unchecked.wl
// Focus: A typed dictionary probe needs a presence check before using its value.
// Expected Error: "TypeError: Type mismatch. Expected String, got (Null | String)."

func main() -> Int {
    let values: Dict(Int, String) = Dict();
    let value: String = values.lookup(1);
    print(value);
    return 0;
}
