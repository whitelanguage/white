// Test: NULL_INTERFACE
// File: tests/diagnostics/failures/test_null_interface.wl
// Focus: Interface storage does not make an interface implicitly nullable.
// Expected Error: "TypeError: Type Named cannot be null."

interface Named {
    func name() -> String;
}

func main() -> Int {
    let value: Named = null;
    return 0;
}
