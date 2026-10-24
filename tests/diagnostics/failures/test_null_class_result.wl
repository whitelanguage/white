// Test: NULL_CLASS_RESULT
// File: tests/diagnostics/failures/test_null_class_result.wl
// Focus: A class result needs Optional to represent an absent object.
// Expected Error: "TypeError: Type Box cannot be null."

class Box {}

func make() -> Box {
    return null;
}

func main() -> Int {
    make();
    return 0;
}
