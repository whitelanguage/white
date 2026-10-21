// Test: VOID_LOCAL
// File: tests/diagnostics/failures/test_void_local.wl
// Focus: Rejecting a Void variable before allocating storage or lowering null.
// Expected Error: "TypeError: Variable 'a' cannot have type Void."

func main() -> Int {
    let a: Void = null;
    return 0;
}
