// Test: NATIVE_REF_NULL
// File: tests/integration/ffi/test_native_ref_null.wl
// Focus: Rejecting a null native address passed to an exported ref parameter.
// Link: native_payloads.c
// Expected Error: "RuntimeError: Null pointer dereference"
import "../../fixtures/native_payloads.wl" as payload


func main() -> Int {
    return payload.native_entry(8, nullptr);
}
