// Test: REFERENCE_PARAMETER_CAPTURE
// File: tests/diagnostics/failures/test_ref_capture.wl
// Focus: Preventing a scoped reference parameter from escaping through a closure.
// Expected Error: "TypeError: Cannot capture reference parameter 'value'."

func make_writer(ref value: Int) -> Function() -> Void {
    func write() -> Void {
        value = 1;
    }
    return write;
}

func main() -> Int {
    return 0;
}
