// Test: STRUCT_DEFAULT_TYPE
// File: tests/diagnostics/failures/test_struct_default_type.wl
// Focus: A field default is checked against the declared field type.
// Expected Error: "TypeError: Type mismatch. Expected Int, got String"

struct Count(value: Int = "wrong")

func main() -> Int {
    let count = Count();
    return 0;
}
