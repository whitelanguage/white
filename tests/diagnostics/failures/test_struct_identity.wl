// Test: STRUCT_IDENTITY
// File: tests/diagnostics/failures/test_struct_identity.wl
// Focus: A value Struct has no implicit reference identity.
// Expected Error: "TypeError: Operator 'is' is not defined for Struct values. Compare explicit pointers instead."

struct Point(x: Int)

func main() -> Int {
    let point = Point(1);
    let same: Bool = point is point;
    return 0;
}
