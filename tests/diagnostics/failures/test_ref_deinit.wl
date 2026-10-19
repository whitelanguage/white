// Test: REFERENCE_DESTRUCTOR_EFFECTS
// File: tests/diagnostics/failures/test_ref_deinit.wl
// Focus: Dropping an unrelated object may still resize the referenced owner through a field.
// Expected Error: "TypeError: Cannot call 'append' while element reference 'first' is active."

class Probe {
    let values: Vector(Int);
    init(values: Vector(Int)) { self.values = values; }
    deinit() { self.values.append(3); }
}

func read(values: Vector(Int), others: Vector(Probe)) -> Int {
    let first = ref values[0];
    others.drop();
    return first;
}

func main() -> Int {
    let values: Vector(Int) = [1, 2];
    let others: Vector(Probe) = [Probe(values)];
    return read(values, others);
}
