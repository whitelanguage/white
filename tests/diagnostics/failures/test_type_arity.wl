// Test: TYPE_ARITY
// File: tests/diagnostics/failures/test_type_arity.wl
// Focus: Type checks require a value and a type operand.
// Expected Error: "TypeError: Type checks require a value followed by a type, expected 2 arguments."

func main() -> Int {
    let checked = is_type(10);
    return 0;
}
