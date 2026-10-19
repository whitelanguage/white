// Test: REFERENCE_TEMPORARY_OWNER
// File: tests/diagnostics/failures/test_ref_temporary.wl
// Focus: Ref arguments require a named owner whose scope covers the call.
// Expected Error: "TypeError: Cannot pass a reference to storage that may move or be released."

func make() -> Vector(Int) { return [1]; }
func set(ref value: Int) -> Void { value = 2; }

func main() -> Int {
    set(ref make()[0]);
    return 0;
}
