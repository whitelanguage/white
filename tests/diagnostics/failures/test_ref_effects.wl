// Test: ELEMENT_REFERENCE_CALLABLE
// File: tests/diagnostics/failures/test_ref_effects.wl
// Focus: Calls through function values cannot hide mutations of referenced storage.
// Expected Error: "TypeError: Cannot call a function with unverified storage effects while element reference 'first' is active."

func grow(values: Vector(Int)) -> Void {
    values.append(3);
}

func main() -> Int {
    let values: Vector(Int) = [1, 2];
    let action = grow;
    let first = ref values[0];
    action(values);
    return first;
}
