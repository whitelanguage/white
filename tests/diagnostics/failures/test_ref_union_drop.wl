// Test: REF_UNION_DROP
// File: tests/diagnostics/failures/test_ref_union_drop.wl
// Focus: Union cleanup must still account for a class destructor which moves referenced storage.
// Expected Error: "TypeError: Cannot call 'append' while element reference 'first' is active."

class Owner {
    let values: Vector(Int);
    init(values: Vector(Int)) { self.values = values; }
    deinit() { self.values.append(3); }
}

func main() -> Int {
    let values: Vector(Int) = [1, 2];
    let owner: Optional(Owner) = Owner(values);
    let first = ref values[0];
    owner = null;
    return first;
}
