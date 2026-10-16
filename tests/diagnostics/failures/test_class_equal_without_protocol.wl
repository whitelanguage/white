// Test: CLASS_EQUAL_WITHOUT_PROTOCOL
// File: tests/diagnostics/failures/test_class_equal_without_protocol.wl
// Focus: A plain Class cannot use value equality as an address comparison.
// Expected Error: "TypeError: Class equality requires matching types implementing Equal. Use 'is' or 'is !' for identity."

class Item {
    init() {}
}

func main() -> Int {
    let item = Item();
    let same: Bool = item == item;
    return 0;
}
