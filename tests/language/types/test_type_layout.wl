// Test: TYPE_LAYOUT
// File: tests/language/types/test_type_layout.wl
// Focus: Compile-time size and alignment queries for concrete value representations.

const POINTER_SIZE -> UIntSize = size_of(AnyPtr);
const POINTER_ALIGN -> UIntSize = align_of(AnyPtr);

interface Marker {
    method value() -> Int;
}

class Box with Marker {
    method value() -> Int { return 1; }
}

func align_up(value -> UIntSize, alignment -> UIntSize) -> UIntSize {
    let remainder -> UIntSize = value % alignment;
    if (remainder == UIntSize(0)) { return value; }
    return value + alignment - remainder;
}

func fallible_size(value_size -> UIntSize, value_align -> UIntSize) -> UIntSize {
    let error_align -> UIntSize = align_of(Long);
    let error_size -> UIntSize = align_up(UIntSize(12), error_align);
    let offset -> UIntSize = align_up(UIntSize(1), error_align) + error_size;
    let layout_align -> UIntSize = error_align;
    if (value_size != UIntSize(0)) {
        offset = align_up(offset, value_align) + value_size;
        if (value_align > layout_align) { layout_align = value_align; }
    }
    return align_up(offset, layout_align);
}

func main() -> Int {
    let primitive_ok -> Bool = size_of(Byte) == UIntSize(1) && size_of(Int) == UIntSize(4) && size_of(Long) == UIntSize(8) && size_of(Int128) == UIntSize(16);
    let size_integer_ok -> Bool = size_of(IntSize) == POINTER_SIZE && size_of(UIntSize) == POINTER_SIZE && align_of(IntSize) == POINTER_ALIGN && align_of(UIntSize) == POINTER_ALIGN;
    let array_ok -> Bool = size_of(Int[4]) == UIntSize(16) && align_of(Int[4]) == UIntSize(4);
    let reference_ok -> Bool = size_of(String) == POINTER_SIZE && size_of(Box) == POINTER_SIZE && size_of(Array(Int)) == POINTER_SIZE && align_of(String) == POINTER_ALIGN;
    let fallible_ok -> Bool = size_of(Void?) == fallible_size(UIntSize(0), UIntSize(1)) && size_of(Int?) == fallible_size(size_of(Int), align_of(Int));
    let aggregate_ok -> Bool = size_of(Marker) == POINTER_SIZE * UIntSize(2) && align_of(Marker) == POINTER_ALIGN && fallible_ok;

    if (primitive_ok && size_integer_ok && array_ok && reference_ok && aggregate_ok) {
        print("PASS: type layout queries");
        return 0;
    }
    print("FAIL: type layout query returned the wrong value");
    return 1;
}
