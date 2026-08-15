// Test: ALIGN_OF_AUTO
// File: tests/diagnostics/failures/test_align_of_auto.wl
// Focus: Rejecting layout queries before an inferred type is known.
// Expected Error: "TypeError: Type 'Auto' must be resolved before its alignment can be determined."

func main() -> Int {
    let value: UIntSize = align_of(Auto);
    return Int(value);
}
