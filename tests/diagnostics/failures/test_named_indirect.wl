// Test: NAMED_INDIRECT_CALL
// File: tests/diagnostics/failures/test_named_indirect.wl
// Focus: Rejecting argument names after a function has been erased to a callable type.
// Expected Error: "InvalidSyntax: Named arguments are not available when calling a Function or Method value"

func subtract(left: Int, right: Int) -> Int { return left - right; }

func main() -> Int {
    let operation: Function(Int) -> Int = subtract;
    operation(right=3, left=10);
    return 0;
}
