// Test: ALIAS_CONVERSION_COLLISION
// File: tests/diagnostics/failures/test_alias_conversion.wl
// Focus: Treating alias and canonical conversion targets as the same type.
// Expected Error: "NameError: class 'Value' already defines a conversion to String"

type String as Text;

class Value {
    type String { return "one"; }
    type Text { return "two"; }
}

func main() -> Int { return 0; }
