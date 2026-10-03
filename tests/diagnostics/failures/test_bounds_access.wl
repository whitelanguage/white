// Test: RUNTIME_BOUNDS_ACCESS
// File: tests/diagnostics/failures/test_bounds_access.wl
// Focus: Reporting an out-of-range Vector access before loading the element.
// Expected Error: "RuntimeError: Index out of bounds"

func main() -> Int {
    let values: Vector(Int) = [1];
    print(values[1]);
    return 0;
}
