// Test: SPREAD_FIXED
// File: tests/diagnostics/failures/test_spread_fixed.wl
// Focus: Rejecting expansion when the target function has no variadic parameter.
// Expected Error: "InvalidSyntax: A spread argument requires a variadic parameter."

func take(value: Int) -> Void {}

func main() -> Int {
    let values: Vector(Int) = [1];
    take(values...);
    return 0;
}
