// Test: MULTIPLE_REFERENCE_OWNERS
// File: tests/diagnostics/failures/test_ref_owners.wl
// Focus: Report the reference to the mutated allocation, not the first unrelated reference.
// Expected Error: "TypeError: Cannot call 'append' while element reference 'second' is active."

func main() -> Int {
    let left: Vector(Int) = [1];
    let right: Vector(Int) = [2];
    let first = ref left[0];
    let second = ref right[0];
    right.append(3);
    return first + second;
}
