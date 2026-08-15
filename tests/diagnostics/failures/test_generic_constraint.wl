// Test: GENERIC_CONSTRAINT
// File: tests/diagnostics/failures/test_generic_constraint.wl
// Focus: Rejecting a type that does not implement a generic interface constraint.
// Expected Error: "TypeError: Type Empty does not satisfy Reader(Int) for 'T'."

interface Reader<T> {
    func read() -> T;
}

class Empty {}

func read_int<T: Reader(Int)>(value: T) -> Int {
    return 0;
}

func main() -> Int {
    read_int(Empty());
    return 0;
}
