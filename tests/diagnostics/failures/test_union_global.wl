// Test: UNION_GLOBAL
// File: tests/diagnostics/failures/test_union_global.wl
// Focus: Dynamic construction is rejected as a static union initializer.
// Expected Error: "TypeError: Global variable initialisation must be a compile-time constant expression."

class Holder {
    init() {}
}

let value: Optional(Holder) = Holder();

func main() -> Int {
    return 0;
}
