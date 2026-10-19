// Test: REFERENCE_DYNAMIC_ARGUMENT
// File: tests/diagnostics/failures/test_ref_dynamic.wl
// Focus: A dynamic callable cannot bypass a temporary element reference check.
// Expected Error: "TypeError: Cannot call a function with unverified storage effects while element reference 'argument' is active."

func invoke(action: Function(ref Int, Vector(Int)) -> Void, values: Vector(Int)) -> Void {
    action(ref values[0], values);
}

func grow(ref first: Int, values: Vector(Int)) -> Void {
    values.append(3);
    first = 10;
}

func main() -> Int {
    let values: Vector(Int) = [1, 2];
    invoke(grow, values);
    return 0;
}
