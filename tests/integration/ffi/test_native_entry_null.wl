// Test: NATIVE_ENTRY_NULL
// File: tests/integration/ffi/test_native_entry_null.wl
// Focus: Rejecting a native null argument before an exported function's body.
// Link: native_payloads.c
// Expected Error: "RuntimeError: Null pointer dereference"
import "../../fixtures/native_payloads.wl" as payload


func main() -> Int {
    return payload.native_entry(0, nullptr);
}
