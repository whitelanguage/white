// Test: REFERENCE_LATE_ALIAS
// File: tests/diagnostics/failures/test_ref_late_alias.wl
// Focus: Copies made after an element reference still share the owner's storage.
// Expected Error: "TypeError: Cannot call 'append' while element reference 'first' is active."

func main() -> Int {
    let values: Vector(Int) = [1];
    let first = ref values[0];
    let other = values;
    other.append(2);
    return first;
}
