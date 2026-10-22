// Test: OPTIONAL_ARRAY
// File: tests/language/types/test_optional_array.wl
// Focus: Inline array payloads retain their identity during checked reads and writes.

let global_array: Optional(Int[2]) = [1, 2];

func main() -> Int {
    let array: Optional(Int[2]) = [10, 20];
    if (array is null) { return 1; }
    array[0] = 42;
    if (array[0] != 42 || array[1] != 20) { return 2; }
    if (global_array is null) { return 3; }
    global_array[1] = 7;
    if (global_array[0] != 1 || global_array[1] != 7) { return 4; }
    array = null;
    if (array is !null) { return 5; }
    print("PASS: optional arrays");
    return 0;
}
