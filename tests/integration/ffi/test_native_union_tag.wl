// Test: NATIVE_UNION_TAG
// File: tests/integration/ffi/test_native_union_tag.wl
// Focus: Rejecting an out-of-range native union tag before payload access.
// Link: native_payloads.c
// Expected Error: "RuntimeError: Invalid native union tag"
import "../../fixtures/native_payloads.wl" as payload


func main() -> Int {
    let absent: Optional(String) = null;
    return payload.native_entry(2, ref absent);
}
