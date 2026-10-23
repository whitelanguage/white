// Test: REF_OPTIONAL_CALL
// File: tests/diagnostics/failures/test_ref_optional_call.wl
// Focus: Effect checking must not keep a global's narrowed type after a call.
// Expected Error: "TypeError: Type mismatch. Expected Int, got (Null | Int)."

let value: Optional(Int) = 42;
func reset() -> Void { value = null; }

func main() -> Int {
    let values: Vector(Int) = [1];
    let first = ref values[0];
    if (value is null) { return first; }
    reset();
    return value;
}
