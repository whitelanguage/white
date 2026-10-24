// Test: NULL_CLASS_ASSIGNMENT
// File: tests/diagnostics/failures/test_null_access.wl
// Focus: Rejecting null before it can become an ordinary class value.
// Expected Error: "TypeError: Type Box cannot be null."

class Box {
    let value: Int = 1;
}

func main() -> Int {
    let box: Box = null;
    print(box.value);
    return 0;
}
