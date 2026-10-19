// Test: REFERENCE_CONSTRUCTOR_ARGUMENT
// File: tests/diagnostics/failures/test_ref_init.wl
// Focus: Constructor reference parameters have the same temporary storage restriction as calls.
// Expected Error: "TypeError: Cannot call a function with unverified storage effects while element reference 'argument' is active."

class Cell {
    init(ref first: Int, values: Vector(Int)) {
        values.append(3);
        first = 10;
    }
}

func main() -> Int {
    let values: Vector(Int) = [1, 2];
    let cell = Cell(ref values[0], values);
    return 0;
}
