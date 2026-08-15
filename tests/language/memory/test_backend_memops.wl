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
    memcpy(string_data(value), string_data(source), UIntSize(6));

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

    print("PASS: Optimized backend memory operations");
    return 0;
}
