// Test: NATIVE_BOX_NULL
// File: tests/integration/ffi/test_native_box_null.wl
// Focus: Rejecting a null String stored in a native struct result.
// Link: native_payloads.c
// Expected Error: "RuntimeError: Null pointer dereference"
import "../../fixtures/native_payloads.wl" as payload


func main() -> Int {
    let box = payload.native_box(nullptr);
    return 0;
}
