// Test: REFERENCE_DEFAULT_ARGUMENT
// File: tests/diagnostics/failures/test_ref_default.wl
// Focus: Reference parameters cannot acquire an element address through a default argument.
// Expected Error: "InvalidSyntax: A reference parameter cannot have a default value."

let values: Vector(Int) = [1, 2];

func set(ref first: Int = ref values[0]) -> Void {
    first = 10;
}

func main() -> Int {
    set();
    return 0;
}
