// Test: VARIADIC_IMPORT
// File: tests/language/modules/test_variadic_import.wl
// Focus: Calling a native variadic function and its default parameter across a module boundary.

import "../../fixtures/pkgs/variadic_provider.wl"

func main() -> Int {
    let values: Vector(Int) = [1, 2, 3];
    if (variadic_provider.total(values..., base=10) != 16) {
        print("FAIL: Cross-module variadic call");
        return 1;
    }
    print("PASS: Cross-module variadic call");
    return 0;
}
