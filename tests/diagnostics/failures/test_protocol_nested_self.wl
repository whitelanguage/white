// Test: PROTOCOL_NESTED_SELF
// File: tests/diagnostics/failures/test_protocol_nested_self.wl
// Focus: Rejecting Self hidden inside an erased callable signature.
// Expected Error: "TypeError: Interface 'Transform' uses Self and can only be used as a static constraint."

interface Transform {
    func transform(callback: Function(Self) -> Self) -> Self;
}

class Value with Transform {
    func transform(callback: Function(Value) -> Value) -> Value {
        return callback(self);
    }
}

func main() -> Int {
    let value: Transform = Value();
    return 0;
}
