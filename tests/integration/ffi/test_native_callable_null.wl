// Test: NATIVE_CALLABLE_NULL
// File: tests/integration/ffi/test_native_callable_null.wl
// Focus: Checking native non-null results through an indirect Function call.
// Link: native_boundary.c
// Expected Error: "RuntimeError: Null pointer dereference"

extern "C" {
    func native_zero() -> String;
}

func main() -> Int {
    let zero: Function() -> String = native_zero;
    let value = zero();
    return 0;
}
