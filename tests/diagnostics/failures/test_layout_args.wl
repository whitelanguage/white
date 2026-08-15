// Test: LAYOUT_ARGUMENT_COUNT
// File: tests/diagnostics/failures/test_layout_args.wl
// Focus: Reporting extra type arguments without emitting follow-up syntax errors.
// Expected Error: "TypeError: Expected 1 arguments, got 2"

func main() -> Int {
    let value: UIntSize = size_of(Int, Float);
    return Int(value);
}
