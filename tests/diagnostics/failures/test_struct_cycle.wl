// Test: STRUCT_LAYOUT_CYCLE
// File: tests/diagnostics/failures/test_struct_cycle.wl
// Focus: Rejecting value-layout cycles that cross more than one struct declaration.
// Expected Error: "TypeError: Struct 'Right' contains itself by value through field 'left'. Use a pointer for recursive storage."

struct Left(right: Right)
struct Right(left: Left)

func main() -> Int {
    return 0;
}
