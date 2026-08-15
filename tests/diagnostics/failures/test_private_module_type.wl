// Test: PRIVATE_MODULE_TYPE
// File: tests/diagnostics/failures/test_private_module_type.wl
// Focus: Private types cannot be named through a module namespace.
// Expected Error: "TypeError: Unknown module type: provider.__PrivateItem"

import "../../fixtures/modules/left/provider.wl" as provider

func main() -> Int {
    let value: provider.__PrivateItem;
    return 0;
}
