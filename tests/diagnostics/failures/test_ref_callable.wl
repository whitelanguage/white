// Test: REFERENCE_CALLABLE_MISMATCH
// File: tests/diagnostics/failures/test_ref_callable.wl
// Focus: Keeping reference parameters in first-class callable signatures.
// Expected Error: "TypeError: Type mismatch. Expected Function(Int) -> Void, got Function(ref Int) -> Void"

func clear(ref value: Int) -> Void {
    value = 0;
}

func main() -> Int {
    let callback: Function(Int) -> Void = clear;
    return 0;
}
