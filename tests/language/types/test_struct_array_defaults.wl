// Test: STRUCT_ARRAY_DEFAULTS
// File: tests/language/types/test_struct_array_defaults.wl
// Focus: inline array defaults, literal arguments, and temporary field indexing.
struct Bytes(values: Byte[3] = [Byte(1), Byte(2), Byte(3)])
struct Names(values: String[2] = ["first", "second"])
struct Matrix(values: Int[2][2] = [[1, 2], [3, 4]])
struct Generic<T>(value: T, values: Byte[3] = [Byte(1), Byte(2), Byte(3)])

func bytes() -> Bytes { return Bytes(); }

func main() -> Int {
    let original = Bytes();
    let changed = original;
    changed.values[0] = Byte(9);
    if (original.values[0] != Byte(1) || changed.values[0] != Byte(9)) { return 1; }
    let explicit = Bytes([Byte(4), Byte(5), Byte(6)]);
    if (explicit.values[1] != Byte(5)) { return 2; }
    let names = Names();
    if (names.values[1] != "second") { return 3; }
    let matrix = Matrix();
    if (matrix.values[1][0] != 3) { return 4; }
    let generic: Generic(Long) = Generic(10L);
    if (generic.values[1] != Byte(2) || generic.value != 10L) { return 5; }
    if (bytes().values[2] != Byte(3)) { return 6; }
    print("PASS: inline array defaults and temporary indexing");
    return 0;
}
