// Test: FALLIBLE_RETURN_CLOSURE
// File: tests/diagnostics/failures/test_fallible_return_closure.wl
// Focus: A local function reports its source type error without a missing-return cascade.
// Expected Error: "TypeError: Type mismatch. Expected UInt64, got Int"

func main() -> Int {
    func convert(value: Int) -> UInt64? {
        return value;
    }
    return 0;
}
