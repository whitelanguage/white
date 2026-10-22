// Test: OPTIONAL_FIELD
// File: tests/diagnostics/failures/test_optional_field.wl
// Focus: A field write can invalidate a check through an aliased class.
// Expected Error: "TypeError: Type mismatch. Expected Int, got (Null | Int)."

class Holder {
    let value: Optional(Int);
    init() { self.value = 42; }
}
func main() -> Int {
    let first = Holder();
    let second = first;
    if (first.value is null) { return 0; }
    second.value = null;
    return first.value;
}
