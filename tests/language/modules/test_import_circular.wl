// Test: CIRCULAR_DEPENDENCY_RESOLUTION
// File: tests/language/modules/test_import_circular.wl
// Focus: Recursive symbol resolution and dependency graph traversal between modules.

import bar from "../../fixtures/pkgs/circular_dep_b.wl"
import foo from "../../fixtures/pkgs/circular_dep_a.wl"

func main() -> Int {
    let a: Int = foo();
    let b: Int = bar();
    
    // verify integrity of mutually recursive function calls
    if (a == 10 && b == 30) {
        print("PASS: Circular dependency resolved correctly");
        return 0;
    }
    
    print("FAIL: Circular dependency logic mismatch");
    return 1;
}