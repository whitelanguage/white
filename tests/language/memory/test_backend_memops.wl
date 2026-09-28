// Test: BACKEND_MEMORY_OPERATIONS
// File: tests/language/memory/test_backend_memops.wl
// Focus: Linking and executing memory operations synthesized by the optimized Windows backend.


extern "C" {
    func memcpy(dest: AnyPtr, src: AnyPtr, count: UIntSize) -> AnyPtr;
    func memmove(dest: AnyPtr, src: AnyPtr, count: UIntSize) -> AnyPtr;
    func memset(dest: AnyPtr, value: Int, count: UIntSize) -> AnyPtr;
}

func string_data(value: String) -> AnyPtr {
    let ptr fields: AnyPtr = AnyPtr(value);
    return fields[0];
}

func main() -> Int {
    let source: String = "ABCDEF";
    let value: String = "......"[:];
    if (memcpy(string_data(value), string_data(source), UIntSize(6)) != string_data(value)) {
        print("FAIL: memcpy did not return its destination");
        return 1;
    }

    let ptr value_bytes: Byte = string_data(value);
    memmove(string_data(value), ref value_bytes[1], UIntSize(5));
    if (value.slice(0, 5) != "BCDEF") {
        print("FAIL: Optimized overlapping copy was corrupted");
        return 1;
    }

    let moved: String = "....."[:];
    memmove(string_data(moved), string_data(value), UIntSize(5));
    if (moved != "BCDEF") {
        print("FAIL: Backend memmove returned corrupted data");
        return 1;
    }

    let filled: String = "...."[:];
    memset(string_data(filled), Int('x'), UIntSize(4));
    if (filled != "xxxx") {
        print("FAIL: Backend memset returned corrupted data");
        return 1;
    }

    let backward: String = "ABCDEF"[:];
    let ptr bytes: Byte = string_data(backward);
    if (memmove(ref bytes[1], bytes, UIntSize(5)) != AnyPtr(ref bytes[1]) || backward != "AABCDE") {
        print("FAIL: backward overlapping copy was corrupted");
        return 1;
    }
    if (memmove(bytes, bytes, UIntSize(6)) != AnyPtr(bytes) || backward != "AABCDE") {
        print("FAIL: self copy was corrupted");
        return 1;
    }
    if (memcpy(nullptr, nullptr, UIntSize(0)) is !nullptr || memmove(nullptr, nullptr, UIntSize(0)) is !nullptr || memset(nullptr, 0, UIntSize(0)) is !nullptr) {
        print("FAIL: zero-length memory operation changed its destination");
        return 1;
    }
    if (memset(bytes, 511, UIntSize(1)) != AnyPtr(bytes) || bytes[0] != Byte(255) || bytes[1] != Byte('A')) {
        print("FAIL: memset did not use the low byte of its value");
        return 1;
    }

    print("PASS: Optimized backend memory operations");
    return 0;
}
