// Test: CLASS_EQUALS_WITHOUT_PROTOCOL
// File: tests/diagnostics/failures/test_class_equals_without_protocol.wl
// Focus: An equals method alone does not declare the Equal protocol.
// Expected Error: "TypeError: Class equality requires matching types implementing Equal. Use 'is' or 'is !' for identity."

class Item {
    init() {}
    func equals(other: Item) -> Bool { return true; }
}

func main() -> Int {
    let item = Item();
    let same = item == item;
    return 0;
}
