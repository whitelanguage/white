// Test: LEGACY_POINTER_DECLARATION
// File: tests/diagnostics/failures/test_legacy_ptr.wl
// Focus: Rejecting the old arrow annotation on a pointer declaration.
// Expected Error: "InvalidSyntax: Type annotations use ':'; write 'ptr value: Type'."

func main() -> Int {
    let ptr value -> Int = nullptr;
    return 0;
}
