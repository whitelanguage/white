// Test: INHERITED_MEMBER_COLLISION
// File: tests/diagnostics/failures/test_member_inherit.wl
// Focus: Rejecting a field that conflicts with an inherited method.
// Expected Error: "NameError: Class 'Child' cannot use 'name' as both a field and a method."

class Parent {
    func name() -> String {
        return "parent";
    }
}

class Child(Parent) {
    let name: String = "child";
}

func main() -> Int {
    return 0;
}
