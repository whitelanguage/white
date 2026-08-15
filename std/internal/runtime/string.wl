// std/internal/runtime/string.wl
// low-level String storage access shared by the standard library

import "memory.wl" as memory

const __STRING_TYPE_ID: Int = 5;
const __OBJECT_HEADER_SIZE: Int = 8;

func alloc(length: Long) -> String {
    if (length < 0L || length > 2147483647L) { return null; }

    let pointer_size: Int = Int(size_of(AnyPtr));
    let value_size: Int = pointer_size + 8;
    let storage_size: Long = Long(__OBJECT_HEADER_SIZE + value_size) + length + 1L;
    let storage: AnyPtr = memory.mem_alloc_zeroed(UIntSize(storage_size));
    if (storage is nullptr) { return null; }

    let ptr header: Int = storage;
    header[0] = 0;
    header[1] = __STRING_TYPE_ID;

    let ptr storage_bytes: Byte = storage;
    let value: AnyPtr = ref storage_bytes[__OBJECT_HEADER_SIZE];
    let buffer: AnyPtr = ref storage_bytes[__OBJECT_HEADER_SIZE + value_size];
    let ptr fields: AnyPtr = value;
    fields[0] = buffer;

    let lengths_address: AnyPtr = ref storage_bytes[__OBJECT_HEADER_SIZE + pointer_size];
    let ptr lengths: Int = lengths_address;
    lengths[0] = Int(length);
    lengths[1] = Int(length);

    let result: String = value;
    return result;
}

func data(value: String) -> AnyPtr {
    if (value is null) { return nullptr; }
    let ptr fields: AnyPtr = AnyPtr(value);
    return fields[0];
}

func set_length(value: String, length: Int) -> Void {
    if (value is null || length < 0) { return; }
    let ptr value_bytes: Byte = AnyPtr(value);
    let lengths_address: AnyPtr = ref value_bytes[Int(size_of(AnyPtr))];
    let ptr lengths: Int = lengths_address;
    if (length > lengths[1]) { return; }
    lengths[0] = length;
    let ptr bytes: Byte = data(value);
    bytes[length] = Byte(0);
}

func from_c_string(value: AnyPtr) -> String {
    if (value is nullptr) { return null; }
    let ptr source: Byte = value;
    let length: Int = 0;
    while (source[length] != Byte(0)) {
        if (length == 2147483647) { return null; }
        length += 1;
    }

    let result: String = alloc(Long(length));
    if (result is null) { return null; }
    memory.mem_copy(data(result), value, UIntSize(length));
    return result;
}

func is_native_text(value: String) -> Bool {
    if (value is null) { return false; }
    let ptr bytes: Byte = data(value);
    let offset: Int = 0;
    while (offset < value.length()) {
        let first: Int = Int(bytes[offset]);
        if (first == 0) { return false; }
        if (first <= 127) {
            offset += 1;
            continue;
        }

        let width: Int = 0;
        if (first >= 194 && first <= 223) { width = 2; }
        else if (first >= 224 && first <= 239) { width = 3; }
        else if (first >= 240 && first <= 244) { width = 4; }
        else { return false; }
        if (offset + width > value.length()) { return false; }

        let second: Int = Int(bytes[offset + 1]);
        if (second < 128 || second > 191) { return false; }
        if (first == 224 && second < 160) { return false; }
        if (first == 237 && second > 159) { return false; }
        if (first == 240 && second < 144) { return false; }
        if (first == 244 && second > 143) { return false; }

        let i: Int = 2;
        while (i < width) {
            let continuation: Int = Int(bytes[offset + i]);
            if (continuation < 128 || continuation > 191) { return false; }
            i += 1;
        }
        offset += width;
    }
    return true;
}

@CompilerLink("utf8_encode_char")
func encode_utf8_char(value: Char) -> String {
    // encode one Unicode scalar as UTF-8
    let scalar: Int = Int(value);
    if (scalar < 0 || scalar > 1114111 || (scalar >= 55296 && scalar <= 57343)) {
        return null;
    }

    let width: Int = 1;
    if (scalar > 127) { width = 2; }
    if (scalar > 2047) { width = 3; }
    if (scalar > 65535) { width = 4; }

    let result: String = alloc(Long(width));
    if (result is null) { return null; }
    let ptr bytes: Byte = data(result);

    if (width == 1) {
        bytes[0] = Byte(scalar);
    } else if (width == 2) {
        bytes[0] = Byte(192 | (scalar >> 6));
        bytes[1] = Byte(128 | (scalar & 63));
    } else if (width == 3) {
        bytes[0] = Byte(224 | (scalar >> 12));
        bytes[1] = Byte(128 | ((scalar >> 6) & 63));
        bytes[2] = Byte(128 | (scalar & 63));
    } else {
        bytes[0] = Byte(240 | (scalar >> 18));
        bytes[1] = Byte(128 | ((scalar >> 12) & 63));
        bytes[2] = Byte(128 | ((scalar >> 6) & 63));
        bytes[3] = Byte(128 | (scalar & 63));
    }
    return result;
}
