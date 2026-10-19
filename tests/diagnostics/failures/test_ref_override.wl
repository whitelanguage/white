// Test: REFERENCE_OVERRIDE_EFFECTS
// File: tests/diagnostics/failures/test_ref_override.wl
// Focus: A method called through a base class must account for overriding bodies.
// Expected Error: "TypeError: Cannot call 'append' while element reference 'first' is active."

class Base {
    func touch(values: Vector(Int)) -> Void { return; }
}

class Child(Base) {
    func touch(values: Vector(Int)) -> Void { values.append(3); }
}

func run(target: Base, values: Vector(Int)) -> Int {
    let first = ref values[0];
    target.touch(values);
    return first;
}

func main() -> Int {
    let values: Vector(Int) = [1, 2];
    return run(Child(), values);
}
