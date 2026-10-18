// Test: REFERENCE_OWNER_ALIAS
// File: tests/diagnostics/failures/test_ref_alias.wl
// Focus: Container aliases must not bypass element reference checks.
// Expected Error: "TypeError: Cannot call 'append' while element reference 'first' is active."

func main() -> Int {
    let values: Vector(Int) = [1, 2];
    let alias = values;
    let first = ref values[0];
    alias.append(3);
    return first;
}
