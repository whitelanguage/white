// Test: ALIAS_IMPORT
// File: tests/integration/tooling/test_alias_import.wl
// Focus: Generic aliases survive selective, wildcard and namespace imports.

import Identity as Same from "fixtures/aliases.wl"
import * from "fixtures/aliases.wl"
import "fixtures/aliases.wl" as aliases

type Optional(Int) as MaybeInt;
type aliases.Maybe(Int) as AlsoInt;

func main() -> Int {
    let text: Same(String) = "alias";
    let values: List(Int) = [10, 20];
    let copied: aliases.Identity(String) = text;
    if (copied != "alias" || values.length() != 2) {
        print("FAIL: imported aliases lost their target type");
        return 1;
    }

    print("PASS: imported generic aliases");
    return 0;
}
