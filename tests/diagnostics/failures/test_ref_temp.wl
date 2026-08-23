// Test: REFERENCE_TO_TEMPORARY
// File: tests/diagnostics/failures/test_ref_temp.wl
// Focus: Rejecting a temporary value passed to a reference parameter.
// Expected Error: "InvalidSyntax: Cannot take ref of r-value."

struct Pair(left: Int, right: Int)

func clear(ref value: Pair) -> Void {
    value.left = 0;
}

func main() -> Int {
    clear(ref Pair(1, 2));
    return 0;
}
