// Test: NAMED_ARGUMENT
// File: tests/diagnostics/failures/test_named_arg.wl
// Focus: Rejecting unknown named arguments.
// Expected Error: "NameError: Unknown argument 'value'"

func take(input: Int) -> Int { return input; }
func main() -> Int { return take(value=1); }
