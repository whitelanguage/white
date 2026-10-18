// Test: SLICE_ELEMENT_REFERENCE
// File: tests/diagnostics/failures/test_ref_slice.wl
// Focus: Slice element bindings remain rejected until their lifetime is tracked.
// Expected Error: "TypeError: Cannot bind a reference to storage that may move or be released."

func main() -> Int {
    let values: Vector(Int) = [1, 2];
    let slice: Array(Int) = ref values[0:2];
    let first = ref slice[0];
    return first;
}
