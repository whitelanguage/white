// Test: NATIVE_SUCCESS_NULL
// File: tests/integration/ffi/test_native_success_null.wl
// Focus: Checking the String payload only on a successful fallible value.
// Link: native_payloads.c
// Expected Error: "RuntimeError: Null pointer dereference"
import "../../fixtures/native_payloads.wl" as payload


func main() -> Int {
    return payload.native_entry(6, nullptr);
}
