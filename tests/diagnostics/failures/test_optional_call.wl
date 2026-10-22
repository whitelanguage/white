// Test: OPTIONAL_CALL
// File: tests/diagnostics/failures/test_optional_call.wl
// Focus: A call can change a checked global.
// Expected Error: "TypeError: Type mismatch. Expected Int, got (Null | Int)."

let value: Optional(Int) = 42;
func reset() -> Void { value = null; }
func main() -> Int {
    if (value is null) { return 0; }
    reset();
    return value;
}
