// Test: FLOAT_HASH_CONSTRAINT
// File: tests/diagnostics/failures/test_float_hash.wl
// Focus: Rejecting floating-point keys from typed dictionaries.
// Expected Error: "TypeError: Type Float does not satisfy protocol.Hash for 'K'."

import Dict from "dict"

func main() -> Int {
    let values: Dict(Float, String) = Dict();
    return 0;
}
