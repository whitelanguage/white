// Test: NULL_GLOBAL_STRING
// File: tests/diagnostics/failures/test_null_text_global.wl
// Focus: Global initializers obey the same nullability rule as local bindings.
// Expected Error: "TypeError: Type String cannot be null."

const TEXT: String = null;

func main() -> Int {
    return 0;
}
