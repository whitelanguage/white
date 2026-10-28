// Test: NATIVE_PAIR_CALLABLE_NULL
// File: tests/fixtures/native_abi_win64/test_native_pair_callable_null.wl
// Target: x86_64-pc-windows-msvc
// Focus: Preserve payload checks in the native aggregate Function adapter.
// Link: native_aggregates.c
// Expected Error: "RuntimeError: Null pointer dereference"
import "../native_aggregates.wl" as native


func main() -> Int {
    let make = native.native_pair_null;
    let pair = make("text");
    print(pair.right);
    return 0;
}
