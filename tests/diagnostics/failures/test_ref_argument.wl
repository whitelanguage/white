// Test: REFERENCE_ARGUMENT_LIFETIME
// File: tests/diagnostics/failures/test_ref_argument.wl
// Focus: An element argument stays valid while the callee runs.
// Expected Error: "TypeError: Cannot call 'append' while element reference 'argument' is active."

func change(ref first: Int, values: Vector(Int)) -> Void {
    values.append(3);
    first = 10;
}

func main() -> Int {
    let values: Vector(Int) = [1, 2];
    change(ref values[0], values);
    return 0;
}
