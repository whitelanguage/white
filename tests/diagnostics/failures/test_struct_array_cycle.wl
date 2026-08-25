// Test: STRUCT_ARRAY_LAYOUT_CYCLE
// File: tests/diagnostics/failures/test_struct_array_cycle.wl
// Focus: Rejecting value-layout cycles hidden behind fixed-size arrays.
// Expected Error: "TypeError: Struct 'Right' contains itself by value through field 'left'. Use a pointer for recursive storage."

struct Left(right: Right[1])
struct Right(left: Left[1])

func main() -> Int {
    return 0;
}
