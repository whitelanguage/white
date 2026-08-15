// Test: UNIMPORTED_ERRORS_NAMESPACE
// File: tests/diagnostics/failures/test_unimported_errors_namespace.wl
// Focus: The errors namespace must require an explicit import.
// Expected Error: "NameError: Undefined variable or function 'errors'."

func main() -> Int {
    let err: Error = errors.Error.InvalidArgument;
    return Int(err);
}
