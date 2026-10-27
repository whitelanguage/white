// Test: NATIVE_ARRAY_NULL
// File: tests/integration/ffi/test_native_array_null.wl
// Focus: Checking every element of native fixed-array storage.
// Link: native_payloads.c
// Expected Error: "RuntimeError: Null pointer dereference"
import "../../fixtures/native_payloads.wl" as payload


func main() -> Int {
    return payload.native_entry(5, "text");
}
