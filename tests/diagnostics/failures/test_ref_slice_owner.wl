// Test: REFERENCE_SLICE_REBIND
// File: tests/diagnostics/failures/test_ref_slice_owner.wl
// Focus: Replacing a copied slice cannot release storage used by its element reference.
// Expected Error: "TypeError: Cannot replace managed storage while element reference 'first' is active."

func main() -> Int {
    let values: Vector(Int) = [1, 2];
    let copied: Array(Int) = values[0:2];
    let first = ref copied[0];
    copied = values[0:1];
    return first;
}
