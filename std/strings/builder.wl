// std/strings/builder.wl

import Error from "errors"
import StringError from "errors.wl"
import "internal/runtime/memory" as memory
import "internal/runtime/string" as runtime_string

class Builder {
    let __storage: String = null;
    let __length: Int = 0;
    let __capacity: Int = 0;

    init(initial_capacity: Int) {
        if (initial_capacity < 64) { initial_capacity = 64; }
        self.__storage = runtime_string.alloc(Long(initial_capacity));
        if (self.__storage is !null) {
            runtime_string.set_length(self.__storage, 0);
            self.__capacity = initial_capacity;
        }
    }

    func __reserve(additional: Int) -> Void? {
        // grow geometrically so a sequence of writes stays linear
        if (additional < 0 || self.__length > 2147483647 - additional) { throw Error.Overflow; }
        let required: Int = self.__length + additional;
        if (required <= self.__capacity) { return; }

        let capacity: Int = self.__capacity;
        if (capacity < 64) { capacity = 64; }
        while (capacity < required) {
            if (capacity > 1073741823) {
                capacity = required;
                break;
            }
            capacity *= 2;
        }

        let replacement: String = runtime_string.alloc(Long(capacity));
        if (replacement is null) { throw Error.OutOfMemory; }
        if (self.__length > 0) { memory.mem_copy(runtime_string.data(replacement), runtime_string.data(self.__storage), UIntSize(self.__length)); }
        runtime_string.set_length(replacement, self.__length);
        self.__storage = replacement;
        self.__capacity = capacity;
        return;
    }

    func reserve(additional: Int) -> Void? {
        self.__reserve(additional)?;
        return;
    }

    func write(value: String) -> Void? {
        if (value is null) { throw Error.InvalidArgument; }
        let length: Int = value.length();
        self.__reserve(length)?;
        if (length > 0) {
            let target: AnyPtr = runtime_string.data(self.__storage);
            let ptr target_bytes: Byte = target;
            memory.mem_copy(ref target_bytes[self.__length], runtime_string.data(value), UIntSize(length));
        }
        self.__length += length;
        runtime_string.set_length(self.__storage, self.__length);
        return;
    }

    func write_byte(value: Byte) -> Void? {
        self.__reserve(1)?;
        let ptr bytes: Byte = runtime_string.data(self.__storage);
        bytes[self.__length] = value;
        self.__length += 1;
        runtime_string.set_length(self.__storage, self.__length);
        return;
    }

    func write_char(value: Char) -> Void? {
        // encode directly into the backing buffer without a temporary String
        let scalar: Int = Int(value);
        if (scalar < 0 || scalar > 1114111 || (scalar >= 55296 && scalar <= 57343)) { throw StringError.InvalidCodePoint; }

        let width: Int = 1;
        if (scalar > 127) { width = 2; }
        if (scalar > 2047) { width = 3; }
        if (scalar > 65535) { width = 4; }
        self.__reserve(width)?;

        let ptr bytes: Byte = runtime_string.data(self.__storage);
        let offset: Int = self.__length;
        if (width == 1) {
            bytes[offset] = Byte(scalar);
        } else if (width == 2) {
            bytes[offset] = Byte(192 | (scalar >> 6));
            bytes[offset + 1] = Byte(128 | (scalar & 63));
        } else if (width == 3) {
            bytes[offset] = Byte(224 | (scalar >> 12));
            bytes[offset + 1] = Byte(128 | ((scalar >> 6) & 63));
            bytes[offset + 2] = Byte(128 | (scalar & 63));
        } else {
            bytes[offset] = Byte(240 | (scalar >> 18));
            bytes[offset + 1] = Byte(128 | ((scalar >> 12) & 63));
            bytes[offset + 2] = Byte(128 | ((scalar >> 6) & 63));
            bytes[offset + 3] = Byte(128 | (scalar & 63));
        }
        self.__length += width;
        runtime_string.set_length(self.__storage, self.__length);
        return;
    }

    func write_int(value: Int) -> Void? {
        self.write_long(Long(value))?;
        return;
    }

    func write_long(value: Long) -> Void? {
        let probe: Long = value;
        let digits: Int = 1;
        while (probe <= -10L || probe >= 10L) {
            probe /= 10L;
            digits += 1;
        }
        let negative: Bool = value < 0L;
        let width: Int = digits;
        if (negative) { width += 1; }
        self.__reserve(width)?;

        let start: Int = self.__length;
        let pos: Int = start + width - 1;
        let work: Long = value;
        if (!negative) { work = 0L - work; }
        let ptr bytes: Byte = runtime_string.data(self.__storage);
        while true {
            bytes[pos] = Byte(Int(0L - (work % 10L)) + 48);
            work /= 10L;
            if (work == 0L) { break; }
            pos -= 1;
        }
        if (negative) { bytes[start] = Byte(45); }
        self.__length += width;
        runtime_string.set_length(self.__storage, self.__length);
        return;
    }

    func write_uint(value: UInt64) -> Void? {
        let probe: UInt64 = value;
        let digits: Int = 1;
        while (probe >= UInt64(10)) {
            probe /= UInt64(10);
            digits += 1;
        }
        self.__reserve(digits)?;

        let pos: Int = self.__length + digits - 1;
        let work: UInt64 = value;
        let ptr bytes: Byte = runtime_string.data(self.__storage);
        while true {
            bytes[pos] = Byte(Int(work % UInt64(10)) + 48);
            work /= UInt64(10);
            if (work == UInt64(0)) { break; }
            pos -= 1;
        }
        self.__length += digits;
        runtime_string.set_length(self.__storage, self.__length);
        return;
    }

    func length() -> Int {
        return self.__length;
    }

    func capacity() -> Int {
        return self.__capacity;
    }

    func is_empty() -> Bool {
        return self.__length == 0;
    }

    func clear() -> Void {
        self.__length = 0;
        if (self.__storage is !null) { runtime_string.set_length(self.__storage, 0); }
    }

    func build() -> String? {
        // detach the buffer so later writes cannot mutate the returned String
        if (self.__storage is null) { throw Error.OutOfMemory; }
        runtime_string.set_length(self.__storage, self.__length);
        if (!self.__storage.is_valid_utf8()) { throw StringError.InvalidUtf8; }

        let result: String = self.__storage;
        self.__storage = null;
        self.__length = 0;
        self.__capacity = 0;
        return result;
    }
}
