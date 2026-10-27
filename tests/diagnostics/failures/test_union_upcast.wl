// Test: UNION_UPCAST
// File: tests/diagnostics/failures/test_union_upcast.wl
// Focus: Rejecting ambiguous implicit class conversion into a union.
// Expected Error: "Type mismatch."

interface Known { func identity() -> Int; }
class Base {}
class Child(Base) with Known { func identity() -> Int { return 1; } }

func main() -> Int {
    let value: Base | Known = Child();
    return 0;
}
