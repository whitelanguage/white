// Test: INTERFACE_GENERIC_METHOD
// File: tests/diagnostics/failures/test_interface_generic_method.wl
// Focus: Rejecting generic methods in dynamically dispatched interfaces.
// Expected Error: "TypeError: Interface methods cannot declare type parameters."

interface Factory {
    func make<T>() -> T;
}

func main() -> Int {
    return 0;
}
