// std/builtin/print.wl
import "internal/io" as standard_io
import "internal/runtime"
import "internal/runtime/string" as runtime_string

@CompilerLink("print_bytes")
func write_bytes(data: AnyPtr, length: Int) -> Void {
    if (data is nullptr) {
        let null_text: String = "null";
        standard_io.write_all(
            standard_io.STDOUT,
            runtime_string.data(null_text),
            null_text.length()
        )?;
        catch(err) { return; }
        return;
    }
    standard_io.write_all(standard_io.STDOUT, data, length)?;
    catch(err) { return; }
}

@CompilerLink("print_raw_string")
func write_raw_string(data: AnyPtr) -> Void {
// raw pointers have no length, so the native boundary still needs one scan
    if (data is nullptr) {
        write_bytes(nullptr, 0);
        return;
    }
    let ptr bytes: Byte = data;
    let length: Int = 0;
    while (bytes[length] != 0) { length += 1; }
    write_bytes(data, length);
}

@CompilerLink("print_char")
func write_char(c: Char) -> Void {
    let encoded: String = runtime_string.encode_utf8_char(c);
    if (encoded is null) { return; }
    write_bytes(runtime_string.data(encoded), encoded.length());
}

@CompilerLink("print_int")
func write_int(value: Int) -> Void {
    let formatted: String = runtime.format_int(value);
    if (formatted is null) { return; }
    write_bytes(runtime_string.data(formatted), formatted.length());
}

@CompilerLink("print_long")
func write_long(value: Long) -> Void {
    let formatted: String = runtime.format_long(value);
    if (formatted is null) { return; }
    write_bytes(runtime_string.data(formatted), formatted.length());
}

@CompilerLink("print_float")
func write_float(value: Float) -> Void {
    let formatted: String = runtime.format_float(value);
    if (formatted is null) { return; }
    write_bytes(runtime_string.data(formatted), formatted.length());
}

@CompilerLink("print_bool")
func write_bool(value: Bool) -> Void {
    let s: String = "false";
    if value { s = "true"; }
    write_bytes(runtime_string.data(s), s.length());
}

@CompilerLink
func print(s: String) -> Void {
    if (s is null) { s = "null"; }
    write_bytes(runtime_string.data(s), s.length());
    let newline: String = "\n";
    write_bytes(runtime_string.data(newline), 1);
}
