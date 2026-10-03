// Test: GENERIC_IMPORT
// File: tests/language/modules/test_generic_import.wl
// Focus: Instantiating generic types and functions imported from another module.

import Box, wrap, unwrap from "../../fixtures/generics/boxes.wl"

func main() -> Int {
    let first = wrap(17);
    let second = wrap<String>("white");
    if (unwrap(first) != 17 || unwrap(second) != "white") { print("FAIL: Generic import"); return 1; }
    print("PASS: Generic import");
    return 0;
}
