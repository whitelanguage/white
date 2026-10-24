// Test: NULL_VECTOR
// File: tests/diagnostics/failures/test_null_vector.wl
// Focus: An empty Vector and an absent Vector are different values.
// Expected Error: "TypeError: Type Vector(Int) cannot be null."

func main() -> Int {
    let values: Vector(Int) = null;
    return 0;
}
