// Test: STRUCT_NOT_IDENTITY
// File: tests/diagnostics/failures/test_struct_not_identity.wl
// Focus: Negating identity does not make a value Struct comparable.
// Expected Error: "TypeError: Operator 'is' is not defined for Struct values. Compare explicit pointers instead."

struct Point(x: Int)

func main() -> Int {
    let point = Point(1);
    let different: Bool = point is !point;
    return 0;
}
