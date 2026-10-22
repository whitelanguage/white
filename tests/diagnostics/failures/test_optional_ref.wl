// Test: OPTIONAL_REF
// File: tests/diagnostics/failures/test_optional_ref.wl
// Focus: A reference argument keeps the declared union storage and cancels its check.
// Expected Error: "TypeError: Type mismatch. Expected Int, got (Null | Int)."

func reset(ref value: Optional(Int)) -> Void { value = null; }
func main() -> Int {
    let value: Optional(Int) = 42;
    if (value is null) { return 0; }
    reset(ref value);
    return value;
}
