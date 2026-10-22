// Test: OPTIONAL_INDEX
// File: tests/diagnostics/failures/test_optional_index.wl
// Focus: An assigned expression cannot change an inline array's active union arm.
// Expected Error: "TypeError: Optional index assignment loses its null check while evaluating the assigned value."

func reset(ref array: Optional(Int[2])) -> Int {
    array = null;
    return 42;
}

func main() -> Int {
    let array: Optional(Int[2]) = [1, 2];
    if (array is null) { return 0; }
    array[0] = reset(ref array);
    return 0;
}
