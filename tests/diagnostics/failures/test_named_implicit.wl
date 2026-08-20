// Test: NAMED_TYPE_IMPLICIT_CONVERSION
// File: tests/diagnostics/failures/test_named_implicit.wl
// Focus: Keeping a named type distinct from its underlying type.
// Expected Error: "TypeError: Type mismatch. Expected Code, got UInt32"

type Code = UInt32;

func main() -> Int {
    let code: Code = 1U;
    return 0;
}
