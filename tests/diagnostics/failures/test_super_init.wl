// Test: CLASS_SUPER_INITIALIZATION
// File: tests/diagnostics/failures/test_super_init.wl
// Focus: Requiring a derived constructor to initialize its parent before its own fields.
// Expected Error: "MissingInitializer: Call super.init(...) before initializing fields of 'Child'."

class Parent {
    let id: Int;

    init(id: Int) -> Void {
        self.id = id;
    }
}

class Child(Parent) {
    let name: String;

    init(id: Int, name: String) -> Void {
        self.name = name;
    }
}

func main() -> Int {
    return 0;
}
