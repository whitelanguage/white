// Test: REFERENCE_MODULE_ALIAS
// File: tests/diagnostics/failures/test_ref_module.wl
// Focus: An ordinary parameter named self does not shift the argument owners in a module call.
// Expected Error: "TypeError: Cannot call 'append' while element reference 'first' is active."

import "../../fixtures/ref_helpers.wl" as helpers


func main() -> Int {
    let values: Vector(Int) = [1, 2];
    let other: Vector(Int) = [3];
    let first = ref values[0];
    helpers.grow(other, values);
    return first;
}
