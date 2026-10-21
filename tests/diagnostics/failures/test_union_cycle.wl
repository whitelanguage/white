// Test: UNION_LAYOUT_CYCLE
// File: tests/diagnostics/failures/test_union_cycle.wl
// Focus: A Null member cannot make recursive value storage finite.
// Expected Error: "TypeError: Struct 'Recursive' contains itself by value through field 'next'. Use a pointer for recursive storage."

struct Recursive(next: Optional(Recursive))

func main() -> Int {
    return 0;
}
