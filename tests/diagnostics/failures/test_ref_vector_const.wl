// Test: CONST_ELEMENT_REFERENCE
// File: tests/diagnostics/failures/test_ref_vector_const.wl
// Focus: Element references preserve the owner's const restriction.
// Expected Error: "TypeError: Cannot bind a mutable reference to constant storage."

func main() -> Int {
    const values: Vector(Int) = [1, 2];
    let first = ref values[0];
    first = 3;
    return 0;
}
