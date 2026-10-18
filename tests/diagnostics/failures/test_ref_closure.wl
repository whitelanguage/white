// Test: ELEMENT_REFERENCE_CLOSURE
// File: tests/diagnostics/failures/test_ref_closure.wl
// Focus: Closure construction cannot introduce unchecked storage effects during an element reference.
// Expected Error: "TypeError: Cannot create a closure with unverified capture effects while element reference 'first' is active."

func main() -> Int {
    let values: Vector(Int) = [1, 2];
    let first = ref values[0];
    func grow() -> Void {
        values.append(3);
    }
    grow();
    return first;
}
