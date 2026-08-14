// Test: GENERIC_DEPTH
// File: tests/diagnostics/failures/test_generic_depth.wl
// Focus: Stopping recursively expanding generic instances before the compiler stack is exhausted.
// Expected Error: "TypeError: Generic instantiation depth exceeds 64."

struct Next<T>(value -> T) {}

func expand<T>(value -> T) -> Int {
    return expand(Next(value));
}

func main() -> Int {
    return expand(1);
}
