// Test: NULL_FUNCTION_ARGUMENT
// File: tests/diagnostics/failures/test_null_function.wl
// Focus: Callable parameters do not admit null without an Optional annotation.
// Expected Error: "TypeError: Type Function() -> Int cannot be null."

func invoke(callback: Function() -> Int) -> Void {}

func main() -> Int {
    invoke(null);
    return 0;
}
