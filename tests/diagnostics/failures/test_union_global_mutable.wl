// Test: UNION_GLOBAL_MUTABLE
// File: tests/diagnostics/failures/test_union_global_mutable.wl
// Focus: Static union initializers cannot read writable globals.
// Expected Error: "Global initializer cannot use non-constant variable 'value'."

let value: Optional(String) = "mutable";
const copy: Int | String | Null = value;

func main() -> Int {
    return 0;
}
