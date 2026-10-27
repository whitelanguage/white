// Test: NATIVE_PAYLOADS
// File: tests/integration/ffi/test_native_payloads.wl
// Focus: Native aggregate ownership and inactive payload bytes at exported entries.
// Link: native_payloads.c
import "../../fixtures/native_payloads.wl" as payload


func main() -> Int {
    let text = "native " + String(42);
    let box = payload.native_box(text);
    if (box.text != text) { return 1; }
    let make = payload.native_box;
    let copy = make(text);
    if (copy.text != text) { return 2; }
    let absent: Optional(String) = null;
    if (payload.native_entry(0, text) != 42) { return 3; }
    if (payload.native_entry(3, ref absent) != 42) { return 4; }
    if (payload.native_entry(4, text) != 42) { return 5; }
    if (payload.native_entry(7, nullptr) != 42) { return 6; }
    if (payload.native_entry(9, text) != 42) { return 7; }
    if (payload.native_entry(11, ref absent) != 42) { return 8; }
    print("PASS: native payload boundaries");
    return 0;
}
