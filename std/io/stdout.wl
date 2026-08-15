// std/io/stdout.wl
// standard output

import "internal/io" as standard_io
import "internal/runtime/string" as runtime_string

func write(value: String) -> Int? {
// write once and return the number of bytes accepted by the operating system
    if (value is null) { value = "null"; }
    let count: Int = standard_io.write(
        standard_io.STDOUT,
        runtime_string.data(value),
        value.length()
    )?;
    return count;
}

func write_all(value: String) -> Void? {
// write the complete string or return an I/O error
    if (value is null) { value = "null"; }
    standard_io.write_all(standard_io.STDOUT, runtime_string.data(value), value.length())?;
    return;
}

func write_line(value: String) -> Void? {
    write_all(value)?;
    write_all("\n")?;
    return;
}

func flush() -> Void? {
    standard_io.flush(standard_io.STDOUT)?;
    return;
}
