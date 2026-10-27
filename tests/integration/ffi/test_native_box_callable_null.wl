// Test: NATIVE_BOX_CALLABLE_NULL
// File: tests/integration/ffi/test_native_box_callable_null.wl
// Focus: Applying aggregate result checks in native Function adapters.
// Link: native_payloads.c
// Expected Error: "RuntimeError: Null pointer dereference"
import "../../fixtures/native_payloads.wl" as payload


func main() -> Int {
    let make = payload.native_box;
    let box = make(nullptr);
    return 0;
}
