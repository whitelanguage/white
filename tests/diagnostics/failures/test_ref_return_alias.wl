// Test: REFERENCE_RETURN_ALIAS
// File: tests/diagnostics/failures/test_ref_return_alias.wl
// Focus: A function can return an alias to the Vector passed by value.
// Expected Error: "TypeError: Cannot call 'append' while element reference 'first' is active."

func same(values: Vector(Int)) -> Vector(Int) {
    return values;
}

func main() -> Int {
    let values: Vector(Int) = [1];
    let alias = same(values);
    let first = ref alias[0];
    values.append(2);
    return first;
}
