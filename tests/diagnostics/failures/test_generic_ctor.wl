// Test: GENERIC_CONSTRUCTOR_INFERENCE
// File: tests/diagnostics/failures/test_generic_ctor.wl
// Focus: Rejecting a generic constructor when neither arguments nor context determine its types.
// Expected Error: "TypeError: Cannot infer type argument 'K' for type 'dict.Dict'."

import Dict from "dict"

func main() -> Int {
    let values: Auto = Dict();
    return 0;
}
