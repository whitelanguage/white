// Test: UNION_ERASED_LAYOUT
// File: tests/diagnostics/failures/test_union_erased.wl
// Focus: A union cannot give a type-erased member a concrete layout.
// Expected Error: "TypeError: Type-erased 'Struct' has no defined size."

func main() -> Int {
    let size = size_of(Struct | Int);
    return 0;
}
