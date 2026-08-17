// Test: NAMED_VARIADIC_PACK
// File: tests/diagnostics/failures/test_named_pack.wl
// Focus: Requiring variadic values to use positional arguments or expansion.
// Expected Error: "TypeError: Variadic parameter 'values' must be supplied with positional arguments."

func take(values: Int...) -> Void {}

func main() -> Int {
    take(values=1);
    return 0;
}
