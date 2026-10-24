// Test: NULL_STRING
// File: tests/diagnostics/failures/test_null_string.wl
// Focus: A String binding needs a string value, including an empty string.
// Expected Error: "TypeError: Type String cannot be null."

func main() -> Int {
    let text: String = null;
    return 0;
}
