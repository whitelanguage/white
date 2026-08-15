// Test: SIZE_INTEGER_TYPES
// File: tests/language/types/test_size_integers.wl
// Focus: Pointer-width integer layout, arithmetic, formatting, and pointer round-tripping.

func main() -> Int {
    let signed: IntSize = IntSize(-7);
    let unsigned: UIntSize = UIntSize(40);
    let raw: AnyPtr = AnyPtr(UIntSize(4096));
    let address: UIntSize = UIntSize(raw);

    let layout_ok: Bool = size_of(IntSize) == size_of(AnyPtr) && size_of(UIntSize) == size_of(AnyPtr);
    let arithmetic_ok: Bool = signed + IntSize(9) == IntSize(2) && unsigned + UIntSize(2) == UIntSize(42);
    let pointer_ok: Bool = address == UIntSize(4096);
    let format_ok: Bool = String(signed) == "-7" && String(unsigned) == "40";

    if (layout_ok && arithmetic_ok && pointer_ok && format_ok) {
        print(UIntSize(40));
        print("PASS: pointer-width integer semantics");
        return 0;
    }
    print("FAIL: pointer-width integer semantics");
    return 1;
}
