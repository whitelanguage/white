// Test: NATIVE_ARRAY_TAG
// File: tests/integration/ffi/test_native_array_tag.wl
// Focus: Checking the second union element after a guarded array iteration.
// Link: native_payloads.c
// Expected Error: "RuntimeError: Invalid native union tag"
import "../../fixtures/native_payloads.wl" as payload


func main() -> Int {
    let absent: Optional(String) = null;
    return payload.native_entry(10, ref absent);
}
