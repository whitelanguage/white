// Test: NAMED_STRUCT_IDENTITY
// File: tests/diagnostics/failures/test_named_struct_identity.wl
// Focus: A distinct named Struct still has value semantics.
// Expected Error: "TypeError: Operator 'is' is not defined for Struct values. Compare explicit pointers instead."

struct Point(x: Int)
type Location = Point;

func main() -> Int {
    let location: Location = Location(Point(1));
    let same: Bool = location is location;
    return 0;
}
