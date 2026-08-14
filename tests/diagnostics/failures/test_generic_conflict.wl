// Test: GENERIC_INFERENCE_CONFLICT
// File: tests/diagnostics/failures/test_generic_conflict.wl
// Focus: Rejecting conflicting deductions for the same type parameter.
// Expected Error: "TypeError: Conflicting types inferred for 'T'."

func choose<T>(left -> T, right -> T) -> T {
    return left;
}

func main() -> Int {
    let value -> Auto = choose(1, "one");
    return 0;
}
