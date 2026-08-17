// Test: CALLABLE_LABEL
// File: tests/diagnostics/failures/test_callable_label.wl
// Focus: Calls through a relabeled Function use the label written in its static type.
// Expected Error: " NameError: Unknown callable argument 'sep'. "

func join(values: String..., sep: String = ",") -> String {
    return "";
}

func main() -> Int {
    let callable: Function(String..., delimiter: String) -> String = join;
    callable("a", "b", sep="|");
    return 0;
}
