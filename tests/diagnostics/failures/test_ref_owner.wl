// Test: REFERENCE_OWNER_REPLACEMENT
// File: tests/diagnostics/failures/test_ref_owner.wl
// Focus: Rebinding the owner cannot release an element allocation with active references.
// Expected Error: "TypeError: Cannot replace managed storage while element reference 'first' is active."

func main() -> Int {
    let values: Vector(Int) = [1, 2];
    let first = ref values[0];
    values = [3, 4];
    return first;
}
