// Test: REFERENCE_CALL_EFFECTS
// File: tests/diagnostics/failures/test_ref_call.wl
// Focus: A helper can invalidate an element through a copied container owner.
// Expected Error: "TypeError: Cannot call 'append' while element reference 'first' is active."

func grow(values: Vector(Int)) -> Void {
    values.append(3);
}

func main() -> Int {
    let values: Vector(Int) = [1, 2];
    let first = ref values[0];
    grow(values);
    return first;
}
