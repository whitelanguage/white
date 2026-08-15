// Test: PACKAGE_FACADE
// File: tests/language/modules/test_package_facade.wl
// Focus: A package facade re-exports public submodules

import "../../fixtures/modules/private_package/_pkg.wl" as sample

func main() -> Int {
    let item: sample.NamedItem = sample.NamedItem(7);
    if (sample.public.value() != 29) { return 1; }
    if (sample.answer() != 29) { return 1; }
    if (item.value != 7 || sample.named_state != 29) { return 1; }
    print("PASS: package facade");
    return 0;
}
