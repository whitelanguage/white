// std/builtin/string.wl
// String operations use the stored length and never scan for a terminator

import "internal/runtime/string" as runtime_string
import Error from "errors"

struct __Utf8Decode(
    value: Char,
    width: Int,
    valid: Bool
)

@CompilerLink
func string_at(self: String, idx: Int) -> Byte {
    if (self is null || idx < 0 || idx >= self.length()) { return 0; }
    let ptr bytes: Byte = runtime_string.data(self);
    return bytes[idx];
}

@CompilerLink
func string_byte_at(self: String, idx: Int) -> Byte? {
    if (self is null || idx < 0 || idx >= self.length()) { throw Error.IndexOutOfBounds; }
    let ptr bytes: Byte = runtime_string.data(self);
    return bytes[idx];
}

func __utf8_continuation(value: Int) -> Bool {
    return value >= 128 && value <= 191;
}

func __utf8_decode(self: String, offset: Int) -> __Utf8Decode {
    // decode one Unicode scalar from a known byte offset
    if (self is null || offset < 0 || offset >= self.length()) {
        return __Utf8Decode(value='\0', width=0, valid=false);
    }

    let ptr bytes: Byte = runtime_string.data(self);
    let length: Int = self.length();
    let first: Int = Int(bytes[offset]);
    if (first <= 127) {
        return __Utf8Decode(value=Char(first), width=1, valid=true);
    }

    if (first >= 194 && first <= 223) {
        if (offset + 1 >= length) {
            return __Utf8Decode(value='\0', width=1, valid=false);
        }
        let second: Int = Int(bytes[offset + 1]);
        if (!__utf8_continuation(second)) {
            return __Utf8Decode(value='\0', width=1, valid=false);
        }
        let scalar: Int = ((first & 31) << 6) | (second & 63);
        return __Utf8Decode(value=Char(scalar), width=2, valid=true);
    }

    if (first >= 224 && first <= 239) {
        if (offset + 2 >= length) {
            return __Utf8Decode(value='\0', width=1, valid=false);
        }
        let second: Int = Int(bytes[offset + 1]);
        let third: Int = Int(bytes[offset + 2]);
        let second_valid: Bool = __utf8_continuation(second);
        if (first == 224) { second_valid = second >= 160 && second <= 191; }
        if (first == 237) { second_valid = second >= 128 && second <= 159; }
        if (!second_valid || !__utf8_continuation(third)) {
            return __Utf8Decode(value='\0', width=1, valid=false);
        }
        let scalar: Int =
            ((first & 15) << 12) | ((second & 63) << 6) | (third & 63);
        return __Utf8Decode(value=Char(scalar), width=3, valid=true);
    }

    if (first >= 240 && first <= 244) {
        if (offset + 3 >= length) {
            return __Utf8Decode(value='\0', width=1, valid=false);
        }
        let second: Int = Int(bytes[offset + 1]);
        let third: Int = Int(bytes[offset + 2]);
        let fourth: Int = Int(bytes[offset + 3]);
        let second_valid: Bool = __utf8_continuation(second);
        if (first == 240) { second_valid = second >= 144 && second <= 191; }
        if (first == 244) { second_valid = second >= 128 && second <= 143; }
        if (!second_valid ||
            !__utf8_continuation(third) ||
            !__utf8_continuation(fourth)) {
            return __Utf8Decode(value='\0', width=1, valid=false);
        }
        let scalar: Int =
            ((first & 7) << 18) |
            ((second & 63) << 12) |
            ((third & 63) << 6) |
            (fourth & 63);
        return __Utf8Decode(value=Char(scalar), width=4, valid=true);
    }

    return __Utf8Decode(value='\0', width=1, valid=false);
}

@CompilerLink
func string_is_valid_utf8(self: String) -> Bool {
    if (self is null) { return false; }
    let offset: Int = 0;
    while (offset < self.length()) {
        let decoded: __Utf8Decode = __utf8_decode(self, offset);
        if (!decoded.valid) { return false; }
        offset += decoded.width;
    }
    return true;
}

@CompilerLink
func string_is_char_boundary(self: String, byte_index: Int) -> Bool {
    if (self is null || byte_index < 0 || byte_index > self.length()) {
        return false;
    }
    if (byte_index == 0 || byte_index == self.length()) { return true; }
    let ptr bytes: Byte = runtime_string.data(self);
    let value: Int = Int(bytes[byte_index]);
    return value < 128 || value > 191;
}

@CompilerLink
func string_char_count(self: String) -> Int? {
    if (self is null) { throw Error.InvalidArgument; }
    let count: Int = 0;
    let offset: Int = 0;
    while (offset < self.length()) {
        let decoded: __Utf8Decode = __utf8_decode(self, offset);
        if (!decoded.valid) { throw Error.InvalidArgument; }
        count += 1;
        offset += decoded.width;
    }
    return count;
}

@CompilerLink
func string_char_at(self: String, index: Int) -> Char? {
    if (self is null || index < 0) { throw Error.IndexOutOfBounds; }
    let current: Int = 0;
    let offset: Int = 0;
    while (offset < self.length()) {
        let decoded: __Utf8Decode = __utf8_decode(self, offset);
        if (!decoded.valid) { throw Error.InvalidArgument; }
        if (current == index) { return decoded.value; }
        current += 1;
        offset += decoded.width;
    }
    throw Error.IndexOutOfBounds;
    return '\0';
}

@CompilerLink
func string_slice(self: String, start: Int, end: Int) -> String {
    if (self is null) { return null; }
    let source_len: Int = self.length();
    if (start < 0) { start = 0; }
    if (end > source_len) { end = source_len; }
    if (start > end) { start = end; }

    let result_len: Int = end - start;
    let result: String = runtime_string.alloc(Long(result_len));
    if (result is null || result_len == 0) { return result; }

    let ptr source: Byte = runtime_string.data(self);
    let ptr output: Byte = runtime_string.data(result);
    let i: Int = 0;
    while (i < result_len) {
        output[i] = source[start + i];
        i += 1;
    }
    return result;
}

@CompilerLink("string_concat")
func string_concat(left: String, right: String) -> String {
    if (left is null || right is null) { return null; }

    let left_len: Int = left.length();
    let right_len: Int = right.length();
    let total_len: Long = Long(left_len) + Long(right_len);
    let result: String = runtime_string.alloc(total_len);
    if (result is null) { return null; }

    let ptr output: Byte = runtime_string.data(result);
    let ptr left_bytes: Byte = runtime_string.data(left);
    let ptr right_bytes: Byte = runtime_string.data(right);
    let i: Int = 0;
    while (i < left_len) {
        output[i] = left_bytes[i];
        i += 1;
    }
    let j: Int = 0;
    while (j < right_len) {
        output[left_len + j] = right_bytes[j];
        j += 1;
    }
    return result;
}

@CompilerLink("string_compare")
func string_compare(left: String, right: String) -> Int {
    if (left is right) { return 0; }
    if (left is null) { return -1; }
    if (right is null) { return 1; }

    let left_len: Int = left.length();
    let right_len: Int = right.length();
    let common_len: Int = left_len;
    if (right_len < common_len) { common_len = right_len; }

    let ptr left_bytes: Byte = runtime_string.data(left);
    let ptr right_bytes: Byte = runtime_string.data(right);
    let i: Int = 0;
    while (i < common_len) {
        let lhs: Int = Int(left_bytes[i]);
        let rhs: Int = Int(right_bytes[i]);
        if (lhs < rhs) { return -1; }
        if (lhs > rhs) { return 1; }
        i += 1;
    }

    if (left_len < right_len) { return -1; }
    if (left_len > right_len) { return 1; }
    return 0;
}

@CompilerLink
func string_starts_with(self: String, prefix: String) -> Bool {
    if (self is null || prefix is null) { return false; }
    let self_len: Int = self.length();
    let prefix_len: Int = prefix.length();
    if (prefix_len > self_len) { return false; }

    let ptr source: Byte = runtime_string.data(self);
    let ptr expected: Byte = runtime_string.data(prefix);
    let i: Int = 0;
    while (i < prefix_len) {
        if (source[i] != expected[i]) { return false; }
        i += 1;
    }
    return true;
}

@CompilerLink
func string_ends_with(self: String, suffix: String) -> Bool {
    if (self is null || suffix is null) { return false; }
    let self_len: Int = self.length();
    let suffix_len: Int = suffix.length();
    if (suffix_len > self_len) { return false; }

    let offset: Int = self_len - suffix_len;
    let ptr source: Byte = runtime_string.data(self);
    let ptr expected: Byte = runtime_string.data(suffix);
    let i: Int = 0;
    while (i < suffix_len) {
        if (source[offset + i] != expected[i]) { return false; }
        i += 1;
    }
    return true;
}
