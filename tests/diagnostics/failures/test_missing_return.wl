// Test: MISSING_RETURN
// File: tests/diagnostics/failures/test_missing_return.wl
// Focus: A value-returning function must return on every reachable path.
// Expected Error: "TypeError: Missing return."

func missing_value() -> Int {
    let value: Int = 1;
}

func main() -> Int {
    return 0;
}
