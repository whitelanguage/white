// Test: OPTIONAL_MEMBERS
// File: tests/language/types/test_optional_members.wl
// Focus: Checked interface, bound method and slice values keep their member types.

interface Readable {
    func read() -> Int;
}

class Probe with Readable {
    let number: Int;
    init(number: Int) { self.number = number; }
    func read() -> Int { return self.number; }
}

func main() -> Int {
    let probe = Probe(42);
    let interface_value: Readable = probe;
    let checked: Optional(Readable) = interface_value;
    if (checked is null) { return 1; }
    if (checked.read() != 42) { return 2; }
    let bound: Method() -> Int = probe.read;
    let callback: Optional(Method() -> Int) = bound;
    if (callback is null) { return 3; }
    if (callback() != 42) { return 4; }
    let values: Vector(Int) = [3, 4];
    let slice: Optional(Array(Int)) = values[:];
    if (slice is null) { return 5; }
    if (slice[1] != 4) { return 6; }
    print("PASS: optional interface, method and slice");
    return 0;
}
