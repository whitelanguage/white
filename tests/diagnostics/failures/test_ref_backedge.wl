// Test: REFERENCE_BACKEDGE_ALIAS
// File: tests/diagnostics/failures/test_ref_backedge.wl
// Focus: A later loop assignment can make a mutation affect referenced storage on the next iteration.
// Expected Error: "TypeError: Cannot call 'append' while element reference 'first' is active."

func main() -> Int {
    let values: Vector(Int) = [1];
    let other: Vector(Int) = [2];
    let i = 0;
    while (i < 2) {
        if true {
            let first = ref values[0];
            other.append(3);
            print(first);
        }
        other = values;
        i++;
    }
    return 0;
}
