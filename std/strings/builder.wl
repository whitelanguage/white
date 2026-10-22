// std/strings/builder.wl

import Error from "errors"
import StringError from "errors.wl"
import "internal/runtime/memory" as memory
import "internal/runtime/string" as runtime_string
import Optional from "builtin/type"


class Builder {
// grows one UTF-8 buffer and turns it into an ordinary String when build is called
    let __storage: Optional(String) = null;
    let __length: Int = 0;
    let __capacity: Int = 0;

    init(initial_capacity: Int) {
        if (initial_capacity < 64) { initial_capacity = 64; }
        let storage: String = runtime_string.try_alloc(Long(initial_capacity))?;
        catch(err) { return; }
        runtime_string.set_length(storage, 0);
        self.__storage = storage;
        self.__capacity = initial_capacity;
    }

    func __buffer() -> String? {
    // keep a local owner while calls may change the builder's backing field
        let storage: Optional(String) = self.__storage;
        if (storage is null) { throw Error.OutOfMemory; }
        return storage;
    }

    func __reserve(additional: Int) -> Void? {
    // grow geometrically so a sequence of writes stays linear
        if (additional < 0 || self.__length > 2147483647 - additional) { throw Error.Overflow; }
        let required: Int = self.__length + additional;
        if (required <= self.__capacity) {
            return;
        }

        let capacity: Int = self.__capacity;
        if (capacity < 64) { capacity = 64; }
        while (capacity < required) {
            if (capacity > 1073741823) {
                capacity = required;
                break;
            }
            capacity *= 2;
        }

        let replacement: String = runtime_string.try_alloc(Long(capacity))?;
        if (self.__length > 0) {
            let storage: String = self.__buffer()?;
            memory.mem_copy(runtime_string.data(replacement), runtime_string.data(storage), UIntSize(self.__length));
        }
        runtime_string.set_length(replacement, self.__length);
        self.__storage = replacement;
        self.__capacity = capacity;
        return;
    }

    func reserve(additional: Int) -> Void? {
    // reserve room beyond the current length, existing bytes are left untouched
        self.__reserve(additional)?;
        return;
    }

    func write(value: String) -> Void? {
    // append a complete UTF-8 string
        if (value is null) {
            throw Error.InvalidArgument;
        }
        let length: Int = value.length();
        if (length == 0) { return; }
        self.__reserve(length)?;
        let storage: String = self.__buffer()?;
        if (length > 0) {
            let target: AnyPtr = runtime_string.data(storage);
            let ptr target_bytes: Byte = target;
            memory.mem_copy(ref target_bytes[self.__length], runtime_string.data(value), UIntSize(length));
        }
        self.__length += length;
        runtime_string.set_length(storage, self.__length);
        return;
    }

    func write_byte(value: Byte) -> Void? {
    // append one raw byte, build will reject the result if the final buffer is not UTF-8
        self.__reserve(1)?;
        let storage: String = self.__buffer()?;
        let ptr bytes: Byte = runtime_string.data(storage);
        bytes[self.__length] = value;
        self.__length += 1;
        runtime_string.set_length(storage, self.__length);
        return;
    }

    func write_char(value: Char) -> Void? {
    // encode one Unicode scalar as UTF-8
        // encode directly into the backing buffer without a temporary String
        let scalar: Int = Int(value);
        if (scalar < 0 || scalar > 1114111 || (scalar >= 55296 && scalar <= 57343)) { throw StringError.InvalidCodePoint; }

        let width: Int = 1;
        if (scalar > 127) { width = 2; }
        if (scalar > 2047) { width = 3; }
        if (scalar > 65535) { width = 4; }
        self.__reserve(width)?;
        let storage: String = self.__buffer()?;
        let ptr bytes: Byte = runtime_string.data(storage);
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
        runtime_string.set_length(storage, self.__length);
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
        if negative { width += 1; }
        self.__reserve(width)?;
        let storage: String = self.__buffer()?;

        let start: Int = self.__length;
        let pos: Int = start + width - 1;
        let work: Long = value;
        if (!negative) { work = 0L - work; }
        let ptr bytes: Byte = runtime_string.data(storage);
        while true {
            bytes[pos] = Byte(Int(0L - (work % 10L)) + 48);
            work /= 10L;
            if (work == 0L) {
                break;
            }
            pos -= 1;
        }
        if negative { bytes[start] = Byte(45); }
        self.__length += width;
        runtime_string.set_length(storage, self.__length);
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
        let storage: String = self.__buffer()?;

        let pos: Int = self.__length + digits - 1;
        let work: UInt64 = value;
        let ptr bytes: Byte = runtime_string.data(storage);
        while true {
            bytes[pos] = Byte(Int(work % UInt64(10)) + 48);
            work /= UInt64(10);
            if (work == UInt64(0)) {
                break;
            }
            pos -= 1;
        }
        self.__length += digits;
        runtime_string.set_length(storage, self.__length);
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
    // retain the allocation so the builder can be reused
        self.__length = 0;
        let storage: Optional(String) = self.__storage;
        if (storage is !null) {
            runtime_string.set_length(storage, 0);
        }
    }

    func build() -> String? {
    // finish the current contents without exposing spare capacity
        // detach the buffer so later writes cannot mutate the returned String
        let storage: Optional(String) = self.__storage;
        if (storage is null) {
            if (self.__length != 0) { throw Error.OutOfMemory; }
            return "";
        }
        runtime_string.set_length(storage, self.__length);
        if (!storage.is_valid_utf8()) { throw StringError.InvalidUtf8; }

        let result: String = storage;
        self.__storage = null;
        self.__length = 0;
        self.__capacity = 0;
        return result;
    }
}
