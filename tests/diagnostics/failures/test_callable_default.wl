// Test: CALLABLE_DEFAULT
// File: tests/diagnostics/failures/test_callable_default.wl
// Focus: Function values do not retain declaration defaults.
// Expected Error: " TypeError: Missing callable argument 'sep'. "

func join(values: String..., sep: String = ",") -> String {
    return "";
}

func main() -> Int {
    let callable = join;
    callable("a", "b");
    return 0;
}
