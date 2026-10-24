// Test: STRUCT_MISSING_INT
// File: tests/diagnostics/failures/test_struct_missing_int.wl
// Focus: Required scalar fields follow the same initialization rule as managed fields.
// Expected Error: "TypeError: Missing initializer for field 'count' of struct 'Entry'."

struct Entry(count: Int)

func main() -> Int {
    let entry = Entry();
    return 0;
}
