// Test: IMPORT_VISIBILITY_RESTRICTION
// File: tests/diagnostics/failures/test_import_restriction.wl
// Focus: Private functions cannot be called across module boundaries.
// Expected Error: "NameError: Function 'restricted_lib.__private_func' is not defined."

import "../../fixtures/pkgs/restricted_lib.wl" as mod

func main() -> Int {
    // verify standard public access
    let a: Int = mod.public_func();

    // trigger access violation: attempting to invoke a triple-underscore private symbol
    // this must be intercepted by the compiler's symbol resolver
    let b: Int = mod.__private_func();

    return 0;
}
