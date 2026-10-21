// Test: UNION_GENERIC_CYCLE
// File: tests/diagnostics/failures/test_union_generic_cycle.wl
// Focus: Generic specialization rejects recursive inline union storage.
// Expected Error: "TypeError: Struct 'Cell(Int)' contains itself by value through field 'next'. Use a pointer for recursive storage."

struct Cell<T>(next: Optional(Cell(T)))
type Cell(Int) as IntCell;

func main() -> Int {
    return 0;
}
