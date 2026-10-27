// Test: TYPE_FUNCTION
// File: tests/diagnostics/failures/test_type_function.wl
// Focus: A compile-time type operand cannot be represented by a runtime function value.
// Expected Error: "Compiler intrinsic 'is_type' cannot be used as a function value."

func main() -> Int {
    let check: Function() -> Bool = is_type;
    return 0;
}
