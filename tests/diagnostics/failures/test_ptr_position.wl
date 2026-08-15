// Test: POINTER_DECLARATION_POSITION
// File: tests/diagnostics/failures/test_ptr_position.wl
// Focus: Rejecting ptr in the type annotation of a pointer declaration.
// Expected Error: "InvalidSyntax: Place 'ptr' before the declared name; write 'ptr value: Type'."

func main() -> Int {
    let target: Int = 1;
    let value: ptr Int = ref target;
    return 0;
}
