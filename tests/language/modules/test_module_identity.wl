// Test: MODULE_PATH_IDENTITY
// File: tests/language/modules/test_module_identity.wl
// Focus: Modules with the same file name keep separate symbols, types, and globals

import "../../fixtures/modules/left/provider.wl" as left
import "../../fixtures/modules/right/provider.wl" as right

func main() -> Int {
    let left_item: left.Item = left.Item(1);
    let right_item: right.Item = right.Item(2);

    left.marker = 31;
    right.marker = 42;

    if (left.label() != "left" || right.label() != "right") { return 1; }
    if (left_item.value != 1 || right_item.value != 2) { return 1; }
    if (left.marker != 31 || right.marker != 42) { return 1; }

    print("PASS: module path identity");
    return 0;
}
