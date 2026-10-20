// Test: NULL_RETURN
// File: tests/diagnostics/failures/test_null_return.wl
// Focus: Reject a null integer return at its source, without backend errors.
// Expected Error: "TypeError: Type Int cannot be null."

func value() -> Int {
    return null;
}

func main() -> Int {
    return value();
}
