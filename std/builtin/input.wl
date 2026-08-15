// std/builtin/input.wl
// interactive standard input

import read_line as stdin_read_line from "../io/stdin.wl"
import read_bytes as stdin_read_bytes from "../io/stdin.wl"
import read_full as stdin_read_full from "../io/stdin.wl"
import read_until as stdin_read_until from "../io/stdin.wl"
import read_all as stdin_read_all from "../io/stdin.wl"
import skip_bytes as stdin_skip_bytes from "../io/stdin.wl"
import write_all as stdout_write_all from "../io/stdout.wl"
import flush as stdout_flush from "../io/stdout.wl"

func __prompt(text: String) -> Void? {
// write prompts without adding a line ending
    if (text is null || text.length() == 0) { return; }
    stdout_write_all(text)?;
    stdout_flush()?;
    return;
}

func read(prompt: String) -> String? {
    __prompt(prompt)?;
    let value: String = stdin_read_line()?;
    return value;
}

func read_bytes(prompt: String, max_bytes: Int) -> String? {
    __prompt(prompt)?;
    let value: String = stdin_read_bytes(max_bytes)?;
    return value;
}

func read_full(prompt: String, byte_count: Int) -> String? {
    __prompt(prompt)?;
    let value: String = stdin_read_full(byte_count)?;
    return value;
}

func read_until(prompt: String, delimiter: Char) -> String? {
    __prompt(prompt)?;
    let value: String = stdin_read_until(delimiter)?;
    return value;
}

func read_all(prompt: String) -> String? {
    __prompt(prompt)?;
    let value: String = stdin_read_all()?;
    return value;
}

func skip_bytes(prompt: String, byte_count: Int) -> Int? {
    __prompt(prompt)?;
    let skipped: Int = stdin_skip_bytes(byte_count)?;
    return skipped;
}
