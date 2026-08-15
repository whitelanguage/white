// Test: LEGACY_CALLABLE_SIGNATURE
// File: tests/diagnostics/failures/test_legacy_callable.wl
// Focus: Rejecting callable types which place the return type in parentheses.
// Expected Error: "InvalidSyntax: Legacy Function signatures are no longer supported; write 'Function(Args) -> Return'."

func identity(value: Int) -> Int {
    return value;
}

func main() -> Int {
    let callback: Function(Int, Int) = identity;
    return callback(1);
}
