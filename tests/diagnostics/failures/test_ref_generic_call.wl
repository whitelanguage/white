// Test: REFERENCE_GENERIC_METHOD
// File: tests/diagnostics/failures/test_ref_generic_call.wl
// Focus: Generic method effects use the concrete instance's parameter types and owner identities.
// Expected Error: "TypeError: Cannot call 'append' while element reference 'first' is active."

class Change {
    func grow<T>(values: Vector(T), value: T) -> Void {
        values.append(value);
    }
}

func main() -> Int {
    let values: Vector(Int) = [1, 2];
    let change = Change();
    let first = ref values[0];
    change.grow(values, 3);
    return first;
}
