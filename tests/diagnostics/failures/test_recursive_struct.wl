// Test: RECURSIVE_STRUCT_LAYOUT
// File: tests/diagnostics/failures/test_recursive_struct.wl
// Focus: Rejecting recursively sized struct fields while allowing pointer-based recursion.
// Expected Error: "TypeError: Struct 'Node' contains itself by value through field 'next'. Use a pointer for recursive storage."

struct Node(next: Node)

func main() -> Int {
    return 0;
}
