// Test: NATIVE_NULL
// File: tests/integration/ffi/test_native_null.wl
// Focus: Rejecting native zero addresses before non-null String ownership.
// Link: native_boundary.c
// Expected Error: "RuntimeError: Null pointer dereference"

extern "C" {
    func native_zero() -> String;
}

func main() -> Int {
    let value = native_zero();
    return 0;
}
