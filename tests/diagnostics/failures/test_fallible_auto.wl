// Test: FALLIBLE_AUTO
// File: tests/diagnostics/failures/test_fallible_auto.wl
// Focus: Preventing Auto from storing an unhandled fallible result.
// Expected Error: "TypeError: Fallible values cannot be stored; handle the call with '?'"

func main() -> Int {
    let value: Auto = input.read("name: ");
    return 0;
}
