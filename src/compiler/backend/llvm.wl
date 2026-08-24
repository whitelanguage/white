// compiler/backend/llvm.wl

import "file"
import "strings"

func llvm_line_end(text: String, start: Int) -> Int {
    let end: Int = start;
    while (end < text.length() && text[end] != '\n') { end++; }
    if (end < text.length()) { end++; }
    return end;
}

func llvm_line_starts_with(text: String, start: Int, end: Int, prefix: String) -> Bool {
    if (end - start < prefix.length()) { return false; }
    let i: Int = 0;
    while (i < prefix.length()) {
        if (text[start + i] != prefix[i]) { return false; }
        i++;
    }
    return true;
}

func llvm_line_equals(text: String, start: Int, end: Int, value: String) -> Bool {
    let content_end: Int = end;
    if (content_end > start && text[content_end - 1] == '\n') { content_end--; }
    if (content_end > start && text[content_end - 1] == '\r') { content_end--; }
    if (content_end - start != value.length()) { return false; }
    return llvm_line_starts_with(text, start, content_end, value);
}

func llvm_line_is_alloca(text: String, start: Int, end: Int) -> Bool {
    let i: Int = start;
    while (i < end && (text[i] == ' ' || text[i] == '\t')) { i++; }
    if (i >= end || text[i] != '%') { return false; }

    let marker: String = " = alloca ";
    while (i + marker.length() <= end) {
        let matched: Bool = true;
        let j: Int = 0;
        while (j < marker.length()) {
            if (text[i + j] != marker[j]) {
                matched = false;
                break;
            }
            j++;
        }
        if matched { return true; }
        i++;
    }
    return false;
}

func llvm_function_end(text: String, start: Int) -> Int {
    let pos: Int = start;
    while (pos < text.length()) {
        let end: Int = llvm_line_end(text, pos);
        if (llvm_line_equals(text, pos, end, "}")) { return end; }
        pos = end;
    }
    return text.length();
}

func llvm_write_function(output: strings.Builder, text: String, start: Int, end: Int) -> Void? {
    // WLC emits fixed-layout stack slots; one lexical slot must be reused by every loop iteration
    let entry_end: Int = start;
    let pos: Int = start;
    while (pos < end) {
        let line_end: Int = llvm_line_end(text, pos);
        if (llvm_line_equals(text, pos, line_end, "entry:")) {
            entry_end = line_end;
            break;
        }
        pos = line_end;
    }
    if (entry_end == start) {
        output.write(text.slice(start, end))?;
        return;
    }

    output.write(text.slice(start, entry_end))?;
    pos = entry_end;
    while (pos < end) {
        let line_end: Int = llvm_line_end(text, pos);
        if (llvm_line_is_alloca(text, pos, line_end)) { output.write(text.slice(pos, line_end))?; }
        pos = line_end;
    }

    pos = entry_end;
    while (pos < end) {
        let line_end: Int = llvm_line_end(text, pos);
        if (!llvm_line_is_alloca(text, pos, line_end)) { output.write(text.slice(pos, line_end))?; }
        pos = line_end;
    }
    return;
}

func hoist_llvm_allocas_text(text: String) -> String? {
    let output: strings.Builder = strings.Builder(text.length());
    let pos: Int = 0;
    while (pos < text.length()) {
        let line_end: Int = llvm_line_end(text, pos);
        if (llvm_line_starts_with(text, pos, line_end, "define ")) {
            let function_end: Int = llvm_function_end(text, line_end);
            llvm_write_function(output, text, pos, function_end)?;
            pos = function_end;
            continue;
        }
        output.write(text.slice(pos, line_end))?;
        pos = line_end;
    }
    return output.build()?;
}

func hoist_llvm_allocas(path: String) -> Void? {
    let input: file.File = file.open(path)?;
    let text: String = input.read_all()?;
    input.close();

    let normalized: String = hoist_llvm_allocas_text(text)?;
    let output: file.File = file.create(path)?;
    output.write_all(normalized)?;
    output.close();
    return;
}
