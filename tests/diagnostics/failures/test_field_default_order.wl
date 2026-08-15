// Test: CLASS_FIELD_DEFAULT_ORDER
// File: tests/diagnostics/failures/test_field_default_order.wl
// Focus: Preventing a field initializer from reading a later field.
// Expected Error: "MissingInitializer: Field 'second' is read before it is initialized."

class WrongOrder {
    let first: Int = self.second;
    let second: Int = 2;
}

func main() -> Int {
    return 0;
}
