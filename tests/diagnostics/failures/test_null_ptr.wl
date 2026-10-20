// Test: NULL_POINTER_RETURN
// File: tests/diagnostics/failures/test_null_ptr.wl
// Focus: Explicit pointer returns require nullptr instead of null.
// Expected Error: "TypeError: 'null' cannot be returned for explicit pointer types. Use 'nullptr'."

func value() -> ptr Int {
    return null;
}

func main() -> Int {
    let ptr pointer: Int = value();
    return 0;
}
