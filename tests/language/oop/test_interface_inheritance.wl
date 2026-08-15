// Test: INHERITED_INTERFACE_AND_METHOD_VALUE
// File: tests/language/oop/test_interface_inheritance.wl
// Focus: Inherited interface conformance and first-class interface methods.

interface Valued {
    func value() -> Int;
}

class Base with Valued {
    func value() -> Int { return 10; }
}

class Child(Base) {
    func value() -> Int { return 20; }
}

func main() -> Int {
    let child: Child = Child();
    let valued: Valued = child;
    let read: Method() -> Int = valued.value;
    if (read() != 20) { print("FAIL: inherited interface dispatch"); return 1; }
    print("PASS: inherited interface and method value");
    return 0;
}
