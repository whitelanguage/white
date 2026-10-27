// Test: TYPE_CHANGED
// File: tests/diagnostics/failures/test_type_changed.wl
// Focus: Assignment invalidates a previous union type check.
// Expected Error: "TypeError: Cannot access a field of (String | Int) before narrowing."

func main() -> Int {
    let value: String | Int = "hello";
    if (is_type(value, String)) {
        value = 10;
        return value.length();
    }
    return 0;
}
