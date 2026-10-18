// Test: REFERENCE_BRANCH_ALIAS
// File: tests/diagnostics/failures/test_ref_branch.wl
// Focus: Possible owner aliases from either branch remain protected.
// Expected Error: "TypeError: Cannot call 'append' while element reference 'first' is active."

func check(flag: Bool) -> Void {
    let values: Vector(Int) = [1];
    let other: Vector(Int) = [2];
    if flag {
        other = values;
    }
    let first = ref values[0];
    other.append(3);
}

func main() -> Int {
    check(true);
    return 0;
}
