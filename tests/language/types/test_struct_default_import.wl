// Test: STRUCT_DEFAULT_IMPORT
// File: tests/language/types/test_struct_default_import.wl
// Focus: Imported defaults retain their defining module and concrete type bindings.

import Settings, GenericSettings, Fixed from "../../fixtures/modules/struct_defaults/provider.wl"
import "../../fixtures/modules/struct_defaults/provider.wl" as provider


func __size() -> Int {
    return 99;
}

const FIXED: Fixed | Null = Fixed();

func main() -> Int {
    let __SIZE = 100;
    let settings = Settings();
    let qualified = provider.Settings();
    let generic: GenericSettings(String) = GenericSettings();
    generic.values.append("hello");
    if (settings.size != 11 || qualified.size != 11 || settings.values.length() != 0 || generic.values[0] != "hello") {
        print("FAIL: imported defaults used caller names");
        return 1;
    }
    if (FIXED is null || FIXED.size != 11) {
        print("FAIL: static default lost its module context");
        return 1;
    }
    print("PASS: imported struct defaults");
    return 0;
}
