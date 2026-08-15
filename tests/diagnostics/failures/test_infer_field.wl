// Test: INFERRED_FIELD_WITHOUT_INITIALIZER
// File: tests/diagnostics/failures/test_infer_field.wl
// Focus: Requiring a type when a class field has no initializer.
// Expected Error: "InvalidSyntax: Expected a type annotation or initializer after 'value'."

class InvalidField {
    let value;
}

func main() -> Int {
    return 0;
}
