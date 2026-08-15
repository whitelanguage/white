// Test: STRING_CONCAT_TYPE
// File: tests/diagnostics/failures/test_string_concat_type.wl
// Focus: Rejecting implicit object-to-string conversion.
// Expected Error: "TypeError: Cannot concatenate String and Value"

class Value { }
func main() -> Int { let text: String = "value=" + Value(); return 0; }
