// Test: TYPED_DICT_GET
// File: tests/diagnostics/failures/test_typed_dict_get.wl
// Focus: Requiring explicit error handling for typed Dict indexing.
// Expected Error: "TypeError: call to fallible function 'get' requires '?'"

import Dict from "dict"

func main() -> Int {
    let values -> Dict(String, Int) = { "one": 1 };
    let value -> Int = values["one"];
    return value;
}
