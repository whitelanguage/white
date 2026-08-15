// Test: NON_CONSTANT_GLOBAL_EXPRESSION
// File: tests/diagnostics/failures/test_const_runtime_value.wl
// Focus: Rejecting mutable globals in constant initializers before LLVM lowering.
// Expected Error: "TypeError: Global initializer cannot use non-constant variable 'DENOMINATOR'."

let DENOMINATOR: Int = 2;
const HALF: Float = 1.0 / DENOMINATOR;

func main() -> Int {
    return 0;
}
