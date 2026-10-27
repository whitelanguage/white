// Test: ANYPTR_NULL_STRING
// File: tests/diagnostics/failures/test_anyptr_null_string.wl
// Focus: Rejecting zero addresses when restoring a non-null String.
// Expected Error: "RuntimeError: Null pointer dereference"

func zero() -> AnyPtr { return nullptr; }

func main() -> Int {
    let value: String = zero();
    return 0;
}
