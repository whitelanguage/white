// Test: REFERENCE_MODULE_EFFECTS
// File: tests/language/control/test_ref_modules.wl
// Focus: Call proofs preserve imported names, generic bindings and ordinary parameters named self.

import "../../fixtures/ref_helpers.wl" as helpers


func main() -> Int {
    let values: Vector(Int) = [1, 2];
    let other: Vector(Int) = [3];
    let reader = helpers.Reader<Int>();
    let generic: helpers.GenericReader = helpers.GenericReader();
    let first = ref values[0];
    helpers.grow(values, other);
    if (helpers.count(values, other) != 4 || first != 1 || reader.read(values) != first || generic.read(values) != first) {
        print("FAIL: Module reference effects");
        return 1;
    }
    print("PASS: Module reference effects");
    return 0;
}
