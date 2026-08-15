// Test: PACKAGE_ALL_IMPORT
// File: tests/language/modules/test_package_all_import.wl
// Focus: All imports include public symbols and public submodule namespaces

import * from "../../fixtures/modules/private_package/_pkg.wl"

func main() -> Int {
    let item: NamedItem = NamedItem(8);
    if (answer() != 29 || public.value() != 29) { return 1; }
    if (item.value != 8 || named_state != 29) { return 1; }
    print("PASS: package star import");
    return 0;
}
