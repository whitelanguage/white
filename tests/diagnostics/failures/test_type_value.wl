// Test: TYPE_VALUE
// File: tests/diagnostics/failures/test_type_value.wl
// Focus: A runtime value cannot stand in for the type operand.
// Expected Error: "TypeError: The second argument to a type check must be a type, got a value."

func main() -> Int {
    let target = 10;
    let checked = is_type(10, target);
    return 0;
}
