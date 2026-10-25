// Test: DICT_NAN32
// File: tests/diagnostics/failures/test_dict_nan32.wl
// Focus: Rejecting Float32 NaN keys after Variant promotion.
// Expected Error: "fatal: Dict key is not hashable"

import "dict"


func main() -> Int {
    let bits: UInt32 = 2143289345U;
    let raw: AnyPtr = ref bits;
    let ptr scalar: Float32 = raw;
    let values: Dict = Dict(8);
    values.put(scalar[0], 1);
    return 0;
}
