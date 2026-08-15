// Test: CONSTANT_FORWARD_REFERENCE
// File: tests/diagnostics/failures/test_const_forward.wl
// Focus: Reporting a forward reference in a global constant expression without entering LLVM lowering.
// Expected Error: "InvalidSyntax: Constant 'FULL' is used before its declaration."

const HALF: Float = FULL / 2;
const FULL: Float = 3.0;

func main() -> Int {
    return 0;
}
