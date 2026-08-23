// Test: REFERENCE_TO_CONSTANT
// File: tests/diagnostics/failures/test_ref_const.wl
// Focus: Rejecting mutable references to const storage.
// Expected Error: "TypeError: Cannot modify value through const access 'VALUE'"

const VALUE: Int = 1;

func clear(ref value: Int) -> Void {
    value = 0;
}

func main() -> Int {
    clear(ref VALUE);
    return 0;
}
