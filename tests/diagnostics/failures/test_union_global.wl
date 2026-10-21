// Test: UNION_GLOBAL
// File: tests/diagnostics/failures/test_union_global.wl
// Focus: Unsupported static union storage reports a source error before lowering.
// Expected Error: "TypeError: Union global initializers are not implemented yet."

let value: Optional(Int) = null;

func main() -> Int {
    return 0;
}
