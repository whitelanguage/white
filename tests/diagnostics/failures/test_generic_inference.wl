// Test: GENERIC_INFERENCE
// File: tests/diagnostics/failures/test_generic_inference.wl
// Focus: Rejecting a generic call when a type parameter cannot be inferred.
// Expected Error: "TypeError: Cannot infer type argument 'T' for function 'make'."

func make<T>() -> T {
    return null;
}

func main() -> Int {
    let value -> Auto = make();
    return 0;
}
