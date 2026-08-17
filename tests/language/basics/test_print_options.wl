// Test: PRINT_OPTIONS
// File: tests/language/basics/test_print_options.wl
// Focus: Print arguments, separators, endings, and sequence expansion.

func main() -> Int {
    let values: Vector(Int) = [1, 2, 3];
    print("PRINT-OPTIONS:", "a", 2, true, sep="|", end="!\n");
    print(values..., sep=",", end="\n");
    print("PASS: Print options");
    return 0;
}
