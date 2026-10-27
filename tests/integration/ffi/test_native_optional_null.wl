// Test: NATIVE_OPTIONAL_NULL
// File: tests/integration/ffi/test_native_optional_null.wl
// Focus: Optional's active String arm still requires a non-null value.
// Link: native_payloads.c
// Expected Error: "RuntimeError: Null pointer dereference"
import "../../fixtures/native_payloads.wl" as payload


func main() -> Int {
    let present: Optional(String) = "text";
    return payload.native_entry(1, ref present);
}
