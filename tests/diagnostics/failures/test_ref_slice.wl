// Test: SLICE_ELEMENT_REFERENCE
// File: tests/diagnostics/failures/test_ref_slice.wl
// Focus: A shared slice reference protects the Vector allocation it names.
// Expected Error: "TypeError: Cannot call 'append' while element reference 'first' is active."

func main() -> Int {
    let values: Vector(Int) = [1, 2];
    let slice: Array(Int) = ref values[0:2];
    let first = ref slice[0];
    values.append(3);
    return first;
}
