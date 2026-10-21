// Test: UNION_LAYOUT
// File: tests/language/types/test_union_layout.wl
// Focus: Union queries reserve aligned inline payloads without allocating values.

type (Int | Bool) as Small;
type (String | Null) as Text;
type (Int128 | Null) as Wide;
type (Small | Null) as Nested;
type (Int | Int) as Single;
type Maybe = Optional(Int);

struct Record(text: String, count: Int)

interface Marker {
    func value() -> Int;
}

class Box {
}

const SMALL_SIZE: UIntSize = size_of(Small);
const WIDE_SIZE: UIntSize = size_of(Wide);

func main() -> Int {
    if (SMALL_SIZE != UIntSize(8) || align_of(Small) != UIntSize(4) ||
        size_of(Nested) != SMALL_SIZE || size_of(Optional(Int)) != SMALL_SIZE ||
        size_of(Maybe) != SMALL_SIZE || size_of(Single) != size_of(Int)) {
        print("FAIL: scalar union layout");
        return 1;
    }

    let pointer_align = align_of(String);
    let text_offset = (UIntSize(4) + pointer_align - UIntSize(1)) / pointer_align * pointer_align;
    if (size_of(Text) != text_offset + size_of(String) || align_of(Text) != pointer_align) {
        print("FAIL: reference union layout", size_of(Text), text_offset, size_of(String), align_of(Text), pointer_align);
        return 1;
    }

    let wide_align = align_of(Int128);
    if (WIDE_SIZE != wide_align + UIntSize(16) || align_of(Wide) != wide_align) {
        print("FAIL: wide union layout");
        return 1;
    }

    if (size_of(Optional(Int[3])) != UIntSize(16) ||
        size_of(Optional(Record)) != pointer_align + size_of(Record) ||
        align_of(Optional(Record)) != align_of(Record) ||
        size_of(Optional(Marker)) != pointer_align + size_of(Marker) ||
        size_of(Optional(Box)) != pointer_align + size_of(Box)) {
        print("FAIL: aggregate union layout");
        return 1;
    }

    print("PASS: union layout queries");
    return 0;
}
