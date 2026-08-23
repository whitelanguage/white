// Test: EMPTY_STRUCT_LAYOUT
// File: tests/language/types/test_empty_struct.wl
// Focus: Giving empty structs a non-zero layout in arrays and vectors.

struct Marker()

func main() -> Int {
    let values: Vector(Marker) = [Marker(), Marker()];
    let copy: Marker = values[1];
    if (size_of(Marker) != UIntSize(1)) {
        print("FAIL: Empty struct layout");
        return 1;
    }

    print(copy);
    print("PASS: Empty struct layout");
    return 0;
}
