// Test: DICT_NAN
// File: tests/diagnostics/failures/test_dict_nan.wl
// Focus: Rejecting NaN keys in a dynamic dictionary on every backend.
// Expected Error: "fatal: Dict key is not hashable"

import "dict"


func main() -> Int {
    let bits: UInt64 = 9221120237041090561UL;
    let raw: AnyPtr = ref bits;
    let ptr scalar: Float = raw;
    let values: Dict = Dict(8);
    values.put(scalar[0], 1);
    return 0;
}
