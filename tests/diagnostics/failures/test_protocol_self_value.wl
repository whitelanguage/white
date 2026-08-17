// Test: PROTOCOL_SELF_VALUE
// File: tests/diagnostics/failures/test_protocol_self_value.wl
// Focus: Keeping Self-based protocols out of type-erased interface values.
// Expected Error: "TypeError: Interface 'protocol.Equal' uses Self and can only be used as a static constraint."

import Equal from "protocol"

class Value with Equal {
    func equals(other: Value) -> Bool {
        return true;
    }
}

func main() -> Int {
    let value: Equal = Value();
    return 0;
}
