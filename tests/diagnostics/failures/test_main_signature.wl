// Test: MAIN_SIGNATURE
// File: tests/diagnostics/failures/test_main_signature.wl
// Focus: Rejecting entry points that cannot be called by the runtime.
// Expected Error: "TypeError: function 'main' must be 'func main() -> Int' or 'func main(argc: Int, ptr argv: String) -> Int'"

func main(value: String) -> String { return value; }
