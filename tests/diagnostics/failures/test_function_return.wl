// Test: FUNCTION_RETURN_TYPE
// File: tests/diagnostics/failures/test_function_return.wl
// Focus: Requiring a return type for an empty Function signature.
// Expected Error: "InvalidSyntax: Function() requires a return type after '->'."

func main() -> Int {
    let callback: Function() = main;
    return 0;
}
