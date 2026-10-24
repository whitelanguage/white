// Test: NULL_METHOD
// File: tests/diagnostics/failures/test_null_method.wl
// Focus: A Method value requires a valid callable and receiver.
// Expected Error: "TypeError: Type Method() -> Int cannot be null."

func main() -> Int {
    let callback: Method() -> Int = null;
    return 0;
}
