// Test: LEGACY_TYPE_ARROW
// File: tests/diagnostics/failures/test_legacy_arrow.wl
// Focus: Rejecting the pre-0.3.5 variable type annotation.
// Expected Error: "InvalidSyntax: Type annotations use ':'; write 'value: Type'."

func main() -> Int {
    let value -> Int = 1;
    return value;
}
