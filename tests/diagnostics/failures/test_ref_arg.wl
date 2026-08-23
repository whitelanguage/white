// Test: REFERENCE_ARGUMENT_REQUIRED
// File: tests/diagnostics/failures/test_ref_arg.wl
// Focus: Requiring explicit ref at calls to reference parameters.
// Expected Error: "TypeError: Expected a reference argument for Int; pass a writable value with 'ref'."

func clear(ref value: Int) -> Void {
    value = 0;
}

func main() -> Int {
    let value: Int = 1;
    clear(value);
    return 0;
}
