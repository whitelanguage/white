// Test: GENERIC_MEMBER_COLLISION
// File: tests/diagnostics/failures/test_generic_member.wl
// Focus: Rejecting a field and method collision in a generic class.
// Expected Error: "NameError: Class 'Box(Int)' cannot use 'value' as both a field and a method."

class Box<T> {
    let value: T;

    init(value: T) -> Void {
        self.value = value;
    }

    func value() -> T {
        return self.value;
    }
}

func main() -> Int {
    let box: Box(Int) = Box(1);
    return 0;
}
