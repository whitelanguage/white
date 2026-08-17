// Test: INTERFACE_CONFORMANCE
// File: tests/diagnostics/failures/test_interface_missing.wl
// Focus: Rejecting conversion from a class that does not implement the interface.
// Expected Error: "TypeError: Class 'Value' does not implement interface 'Readable'."

interface Readable { func read() -> Int; }
class Value { func read() -> Int { return 1; } }
func main() -> Int { let value: Readable = Value(); return 0; }
