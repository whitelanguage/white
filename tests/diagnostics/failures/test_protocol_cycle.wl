// Test: PROTOCOL_INHERITANCE_CYCLE
// File: tests/diagnostics/failures/test_protocol_cycle.wl
// Focus: Rejecting cycles in interface inheritance.
// Expected Error: "TypeError: Interface inheritance cycle involving 'Left'."

interface Left with Right {
    func left() -> Int;
}

interface Right with Left {
    func right() -> Int;
}

func main() -> Int {
    return 0;
}
