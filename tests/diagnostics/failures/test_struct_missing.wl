// Test: STRUCT_MISSING
// File: tests/diagnostics/failures/test_struct_missing.wl
// Focus: A required field cannot receive an implicit zero initializer.
// Expected Error: "TypeError: Missing initializer for field 'name' of struct 'Entry'."

struct Entry(name: String, count: Int = 0)

func main() -> Int {
    let entry = Entry(count=4);
    return 0;
}
