// Test: REFERENCE_LOOP_MUTATION
// File: tests/diagnostics/failures/test_ref_loop.wl
// Focus: A loop body cannot resize storage referenced in the surrounding block.
// Expected Error: "TypeError: Cannot call 'append' while element reference 'first' is active."

func main() -> Int {
    let values: Vector(Int) = [1, 2];
    let first = ref values[0];
    let i = 0;
    while (i < 2) {
        values.append(i);
        i++;
    }
    return first;
}
