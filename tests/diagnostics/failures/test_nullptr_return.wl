// Test: NULLPTR_VALUE_RETURN
// File: tests/diagnostics/failures/test_nullptr_return.wl
// Focus: nullptr cannot be returned as an ordinary integer value.
// Expected Error: "TypeError: 'nullptr' can only be returned for explicit pointer types."

func value() -> Int {
    return nullptr;
}

func main() -> Int {
    return value();
}
