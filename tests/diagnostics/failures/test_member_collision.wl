// Test: CLASS_MEMBER_COLLISION
// File: tests/diagnostics/failures/test_member_collision.wl
// Focus: Rejecting a field and method with the same name.
// Expected Error: "NameError: Class 'Example' cannot use 'name' as both a field and a method."

class Example {
    let name: String = "field";

    func name() -> String {
        return "method";
    }
}

func main() -> Int {
    return 0;
}
