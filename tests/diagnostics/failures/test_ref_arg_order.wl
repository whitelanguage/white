// Test: REFERENCE_ARGUMENT_ORDER
// File: tests/diagnostics/failures/test_ref_arg_order.wl
// Focus: A later argument must not resize storage whose element address was already taken.
// Expected Error: "TypeError: Cannot call 'append' while element reference 'argument' is active."

func grow(values: Vector(Int)) -> Int {
    values.append(3);
    return 10;
}

func set(ref first: Int, amount: Int) -> Void {
    first = amount;
}

func main() -> Int {
    let values: Vector(Int) = [1, 2];
    set(amount=grow(values), first=ref values[0]);
    return 0;
}
