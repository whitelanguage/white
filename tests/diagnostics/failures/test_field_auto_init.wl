// Test: CLASS_FIELD_AUTO_WITHOUT_INITIALIZER
// File: tests/diagnostics/failures/test_field_auto_init.wl
// Focus: Requiring an explicit type for a class field without an initializer.
// Expected Error: "TypeError: field 'value' needs an explicit type when it has no initializer."

class Inferred {
    let value: Auto;

    init() -> Void {
        self.value = 1;
    }
}

func main() -> Int {
    return 0;
}
