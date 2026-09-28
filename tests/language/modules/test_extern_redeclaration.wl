// Test: EXTERN_REDECLARATION
// File: tests/language/modules/test_extern_redeclaration.wl
// Focus: Compatible native declarations in separate modules share one backend symbol.

import "../../fixtures/ffi/extern_redeclaration.wl"

extern "C" {
    func external_redeclaration_probe(value: Int) -> Int;
}

func main() -> Int {
    print("PASS: Compatible extern redeclaration");
    return 0;
}
