// Test: TYPED_DICT_KEY
// File: tests/diagnostics/failures/test_typed_dict_key.wl
// Focus: Rejecting mutable containers as typed Dict keys.
// Expected Error: "TypeError: Type Vector(Int) does not satisfy hash.Hash for 'K'."

import Dict from "dict"

func main() -> Int {
    let values -> Dict(Vector(Int), String) = Dict();
    return 0;
}
