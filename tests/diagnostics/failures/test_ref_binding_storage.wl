// Test: UNSTABLE_REFERENCE_BINDING
// File: tests/diagnostics/failures/test_ref_binding_storage.wl
// Focus: Rejecting aliases to storage invalidated by container growth.
// Expected Error: "TypeError: Cannot call 'append' while element reference 'first' is active."

func main() -> Int {
    let values: Vector(Int) = [1, 2];
    let first: Int = ref values[0];
    first = 10;
    values.append(3);
    return 0;
}
