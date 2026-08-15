// Test: INFERRED_LOCAL_WITHOUT_INITIALIZER
// File: tests/diagnostics/failures/test_infer_missing.wl
// Focus: Requiring an initializer when a local declaration omits its type.
// Expected Error: "InvalidSyntax: Expected a type annotation or initializer after 'value'."

func main() -> Int {
    let value;
    return 0;
}
