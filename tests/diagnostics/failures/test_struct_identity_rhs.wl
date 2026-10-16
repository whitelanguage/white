// Test: STRUCT_IDENTITY_RHS
// File: tests/diagnostics/failures/test_struct_identity_rhs.wl
// Focus: Identity validation also checks the right operand.
// Expected Error: "TypeError: Operator 'is' is not defined for Struct values. Compare explicit pointers instead."

struct Point(x: Int)

func main() -> Int {
    let point = Point(1);
    let ptr address: Point = ref point;
    let same: Bool = address is point;
    return 0;
}
