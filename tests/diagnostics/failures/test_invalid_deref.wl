// Test: INVALID_DEREFERENCE
// File: tests/diagnostics/failures/test_invalid_deref.wl
// Focus: Dereferencing a non-pointer value must produce a type diagnostic.
// Expected Error: "TypeError: Attempt to dereference non-pointer."

func main() -> Int {
    let value: Int = 7;
    return deref value;
}
