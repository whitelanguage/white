// Test: INSTANCE_INT
// File: tests/diagnostics/failures/test_instance_int.wl
// Focus: Instance tests reject primitive values.
// Expected Error: "TypeError: is_instance requires a class instance, got Int."

class Animal {}

func main() -> Int {
    let checked = is_instance(10, Animal);
    return 0;
}
