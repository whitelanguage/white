// Test: SELF_UNION_INTERFACE
// File: tests/diagnostics/failures/test_self_union.wl
// Focus: Self inside a union keeps an interface restricted to static constraints.
// Expected Error: "TypeError: Interface 'Link' uses Self and can only be used as a static constraint."

interface Link {
    func next() -> Self | Null;
}

class Item with Link {
    func next() -> Item | Null { return null; }
}

func main() -> Int {
    let item = Item();
    let erased: Link = item;
    return 0;
}
