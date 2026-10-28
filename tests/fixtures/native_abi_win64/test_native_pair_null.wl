// Test: NATIVE_PAIR_NULL
// File: tests/fixtures/native_abi_win64/test_native_pair_null.wl
// Target: x86_64-pc-windows-msvc
// Focus: Check a managed field after decoding a native indirect result.
// Link: native_aggregates.c
// Expected Error: "RuntimeError: Null pointer dereference"
import "../native_aggregates.wl" as native


func main() -> Int {
    let pair = native.native_pair_null("text");
    print(pair.right);
    return 0;
}
