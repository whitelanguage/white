// Test: INSTANCE_TYPE
// File: tests/diagnostics/failures/test_instance_type.wl
// Focus: Instance tests require a class as the second argument.
// Expected Error: "TypeError: The second argument to is_instance must be a class type."

class Animal {}

func main() -> Int {
    let checked = is_instance(Animal(), String);
    return 0;
}
