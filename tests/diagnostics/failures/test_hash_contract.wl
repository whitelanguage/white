// Test: HASH_CONTRACT
// File: tests/diagnostics/failures/test_hash_contract.wl
// Focus: Requiring equality whenever a class implements Hash.
// Expected Error: "NameError: Class 'Key' does not implement interface method 'equals'."

import Hash from "protocol"

class Key with Hash {
    func hash() -> Int {
        return 1;
    }
}

func main() -> Int {
    let value: Key = Key();
    return 0;
}
