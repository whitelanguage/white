// Test: REFERENCE_ELEMENT_REMOVAL
// File: tests/diagnostics/failures/test_ref_drop.wl
// Focus: Removing an element is unsafe even when the allocation address stays unchanged.
// Expected Error: "TypeError: Cannot call 'drop' while element reference 'last' is active."

func main() -> Int {
    let values: Vector(Int) = [1, 2];
    let last = ref values[1];
    values.drop();
    return last;
}
