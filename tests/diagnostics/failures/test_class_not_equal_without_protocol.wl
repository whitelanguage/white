// Test: CLASS_NOT_EQUAL_WITHOUT_PROTOCOL
// File: tests/diagnostics/failures/test_class_not_equal_without_protocol.wl
// Focus: Inequality follows the same protocol rule as equality.
// Expected Error: "TypeError: Class equality requires matching types implementing Equal. Use 'is' or 'is !' for identity."

class Item {
    init() {}
}

func main() -> Int {
    let item = Item();
    let different: Bool = item != item;
    return 0;
}
