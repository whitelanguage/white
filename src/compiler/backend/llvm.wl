// src/compiler/backend/llvm.wl
import "file"
import "strings"


func llvm_target_data_layout(target: String) -> String {
// LLVM fixes implicit load/store alignment while parsing, before Clang selects the target
    if (target == "armv7-unknown-linux-gnueabihf") {
        return "e-m:e-p:32:32-Fi8-i64:64-v128:64:128-a:0:32-n32-S64";
    }
    if (target == "i686-pc-windows-msvc") {
        return "e-m:x-p:32:32-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32-a:0:32-S32";
    }
    if (target == "i686-unknown-linux-gnu") {
        return "e-m:e-p:32:32-p270:32:32-p271:32:32-p272:64:64-i128:128-f64:32:64-f80:32-n8:16:32-S128";
    }
    if (target == "x86_64-pc-windows-msvc") {
        return "e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128";
    }
    if (target == "x86_64-unknown-linux-gnu") {
        return "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128";
    }
    if (target == "aarch64-unknown-linux-gnu") {
        return "e-m:e-p270:32:32-p271:32:32-p272:64:64-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128-Fn32";
    }
    if (target == "x86_64-apple-darwin") {
        return "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128";
    }
    if (target == "arm64-apple-darwin" || target == "aarch64-apple-darwin") {
        return "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32";
    }
    return "";
}

func llvm_line_end(text: String, start: Int) -> Int {
    let end: Int = start;
    while (end < text.length() && text[end] != '\n') { end++; }
    if (end < text.length()) { end++; }
    return end;
}

func llvm_header_end(text: String) -> Int {
// delayed type declarations belong after both target directives, LLVM rejects a later triple
    let end: Int = 0;
    while (end < text.length()) {
        let next: Int = llvm_line_end(text, end);
        if (!llvm_line_starts_with(text, end, next, "target triple = ") &&
            !llvm_line_starts_with(text, end, next, "target datalayout = ")) {
            break;
        }
        end = next;
    }
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
// WLC emits fixed-layout stack slots, one lexical slot must be reused by every loop iteration
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
        if (llvm_line_is_alloca(text, pos, line_end)) {
            output.write(text.slice(pos, line_end))?;
        }
        pos = line_end;
    }

    pos = entry_end;
    while (pos < end) {
        let line_end: Int = llvm_line_end(text, pos);
        if (!llvm_line_is_alloca(text, pos, line_end)) {
            output.write(text.slice(pos, line_end))?;
        }
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
