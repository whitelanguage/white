// std/io/stdin.wl
// standard input

import "internal/io" as standard_io
import "internal/runtime/string" as runtime_string
import Error as CoreError from "errors"
import Error from "errors.wl"

const __BUFFER_SIZE: Int = 8192;

let __input_buffer: String = null;
let __buffer_start: Int = 0;
let __buffer_end: Int = 0;
let __reached_eof: Bool = false;

func __ensure_buffer() -> Void? {
    if (__input_buffer is !null) { return; }
    __input_buffer = runtime_string.alloc(Long(__BUFFER_SIZE));
    if (__input_buffer is null) { throw CoreError.OutOfMemory; }
    runtime_string.set_length(__input_buffer, 0);
    return;
}

func __fill_buffer() -> Int? {
    __ensure_buffer()?;
    if __reached_eof { return 0; }

    let count: Int = standard_io.read(
        standard_io.STDIN,
        runtime_string.data(__input_buffer),
        __BUFFER_SIZE
    )?;
    __buffer_start = 0;
    __buffer_end = count;
    runtime_string.set_length(__input_buffer, count);
    if (count == 0) { __reached_eof = true; }
    return count;
}

func __copy_available(target: AnyPtr, target_offset: Int, count: Int) -> Int {
    let available: Int = __buffer_end - __buffer_start;
    let copied: Int = count;
    if (copied > available) { copied = available; }

    let ptr source: Byte = runtime_string.data(__input_buffer);
    let ptr output: Byte = target;
    let i: Int = 0;
    while (i < copied) {
        output[target_offset + i] = source[__buffer_start + i];
        i += 1;
    }
    __buffer_start += copied;
    return copied;
}

func __join(chunks: Vector(String), total_length: Int) -> String? {
    let result: String = runtime_string.alloc(Long(total_length));
    if (result is null) { throw CoreError.OutOfMemory; }
    let ptr output: Byte = runtime_string.data(result);

    let offset: Int = 0;
    let chunk_index: Int = 0;
    while (chunk_index < chunks.length()) {
        let chunk: String = chunks[chunk_index];
        let ptr source: Byte = runtime_string.data(chunk);
        let i: Int = 0;
        while (i < chunk.length()) {
            output[offset + i] = source[i];
            i += 1;
        }
        offset += chunk.length();
        chunk_index += 1;
    }
    return result;
}

func read_bytes(max_bytes: Int) -> String? {
// read up to max_bytes, an empty string marks end of input
    if (max_bytes < 0) { throw CoreError.InvalidArgument; }
    if (max_bytes == 0) {
        let empty: String = runtime_string.alloc(0L);
        if (empty is null) { throw CoreError.OutOfMemory; }
        return empty;
    }
    if (__buffer_start == __buffer_end) {
        let count: Int = __fill_buffer()?;
        if (count == 0) {
            let empty: String = runtime_string.alloc(0L);
            if (empty is null) { throw CoreError.OutOfMemory; }
            return empty;
        }
    }

    let count: Int = __buffer_end - __buffer_start;
    if (count > max_bytes) { count = max_bytes; }
    let result: String = runtime_string.alloc(Long(count));
    if (result is null) { throw CoreError.OutOfMemory; }
    __copy_available(runtime_string.data(result), 0, count);
    return result;
}

func read_full(byte_count: Int) -> String? {
// read exactly byte_count bytes, a short final read reports EndOfFile
    if (byte_count < 0) { throw CoreError.InvalidArgument; }
    let result: String = runtime_string.alloc(Long(byte_count));
    if (result is null) { throw CoreError.OutOfMemory; }

    let offset: Int = 0;
    while (offset < byte_count) {
        if (__buffer_start == __buffer_end) {
            let count: Int = __fill_buffer()?;
            if (count == 0) { throw Error.EndOfFile; }
        }
        offset += __copy_available(runtime_string.data(result), offset, byte_count - offset);
    }
    return result;
}

func read_until(delimiter: Char) -> String? {
// include the delimiter in the returned string
    let chunks: Vector(String) = [];
    let total_length: Int = 0;

    while true {
        if (__buffer_start == __buffer_end) {
            let count: Int = __fill_buffer()?;
            if (count == 0) {
                if (total_length == 0) { throw Error.EndOfFile; }
                let result: String = __join(chunks, total_length)?;
                return result;
            }
        }

        let ptr bytes: Byte = runtime_string.data(__input_buffer);
        let end: Int = __buffer_start;
        while (end < __buffer_end && Char(bytes[end]) != delimiter) { end += 1; }
        let found_delimiter: Bool = end < __buffer_end;
        if found_delimiter { end += 1; }

        let chunk: String = __input_buffer.slice(__buffer_start, end);
        if (total_length > 2147483647 - chunk.length()) { throw CoreError.Overflow; }
        chunks.append(chunk);
        total_length += chunk.length();
        __buffer_start = end;

        if found_delimiter {
            let result: String = __join(chunks, total_length)?;
            return result;
        }
    }
}

func read_line() -> String? {
// remove one trailing LF or CRLF, EOF remains distinct from an empty line
    let line: String = read_until('\n')?;
    let end: Int = line.length();
    if (end > 0 && line[end - 1] == '\n') { end -= 1; }
    if (end > 0 && line[end - 1] == '\r') { end -= 1; }
    return line.slice(0, end);
}

func read_all() -> String? {
// consume all remaining bytes from standard input
    let chunks: Vector(String) = [];
    let total_length: Int = 0;

    while true {
        let chunk: String = read_bytes(__BUFFER_SIZE)?;
        if (chunk.length() == 0) {
            let result: String = __join(chunks, total_length)?;
            return result;
        }
        if (total_length > 2147483647 - chunk.length()) { throw CoreError.Overflow; }
        chunks.append(chunk);
        total_length += chunk.length();
    }
}

func skip_bytes(byte_count: Int) -> Int? {
// skip up to byte_count bytes and return the number consumed
    if (byte_count < 0) { throw CoreError.InvalidArgument; }
    let skipped: Int = 0;
    while (skipped < byte_count) {
        let chunk: String = read_bytes(byte_count - skipped)?;
        if (chunk.length() == 0) { return skipped; }
        skipped += chunk.length();
    }
    return skipped;
}
