// core/WhitelangExceptions.wl
import "file"
import "process"
import Dict from "dict"

let GLOBAL_ERROR_COUNT -> Int = 0;
let LAST_ERROR_FILE -> String = "";
let CLEAN_TMP_LL -> String = "";
let ACTIVE_FILE -> file.File = null;
let ERROR_BUFFER -> Vector(String) = null;
let REPORTED_ERRORS -> Dict(String, Bool) = null;
let STRUCTURED_ERRORS -> Vector(Struct) = null;
let COLLECT_ERRORS_ONLY -> Bool = false;

const DIAGNOSTIC_ERROR -> Int = 1;
const DIAGNOSTIC_WARNING -> Int = 2;
const DIAGNOSTIC_INFO -> Int = 3;
const DIAGNOSTIC_HINT -> Int = 4;

struct Position(
    idx  -> Int,
    ln   -> Int,
    col  -> Int,
    text -> String,
    fn   -> String
)

struct SourcePosition(
    byte_offset   -> Int,
    line          -> Int,
    byte_column   -> Int,
    unicode_column -> Int,
    utf16_column  -> Int
)

struct SourceRange(
    file  -> String,
    start -> SourcePosition,
    end   -> SourcePosition
)

struct DiagnosticNote(
    message -> String,
    range   -> SourceRange
)

struct CompilerDiagnostic(
    code     -> String,
    severity -> Int,
    category -> String,
    message  -> String,
    pos      -> Position,
    range    -> SourceRange,
    notes    -> Vector(Struct)
)

struct __SourceUnit(
    scalar -> Int,
    width  -> Int,
    valid  -> Bool
)

func __source_unit(text -> String, offset -> Int) -> __SourceUnit {
    if (text is null || offset < 0 || offset >= text.length()) {
        return __SourceUnit(scalar=0, width=0, valid=true);
    }

    let first -> Int = Int(text[offset]);
    if (first <= 127) {
        return __SourceUnit(scalar=first, width=1, valid=true);
    }

    if (first >= 194 && first <= 223 && offset + 1 < text.length()) {
        let second -> Int = Int(text[offset + 1]);
        if (second >= 128 && second <= 191) {
            return __SourceUnit(
                scalar=((first & 31) << 6) | (second & 63),
                width=2,
                valid=true
            );
        }
    }

    if (first >= 224 && first <= 239 && offset + 2 < text.length()) {
        let second -> Int = Int(text[offset + 1]);
        let third -> Int = Int(text[offset + 2]);
        let second_valid -> Bool = second >= 128 && second <= 191;
        if (first == 224) { second_valid = second >= 160 && second <= 191; }
        if (first == 237) { second_valid = second >= 128 && second <= 159; }
        if (second_valid && third >= 128 && third <= 191) {
            return __SourceUnit(
                scalar=((first & 15) << 12) |
                       ((second & 63) << 6) |
                       (third & 63),
                width=3,
                valid=true
            );
        }
    }

    if (first >= 240 && first <= 244 && offset + 3 < text.length()) {
        let second -> Int = Int(text[offset + 1]);
        let third -> Int = Int(text[offset + 2]);
        let fourth -> Int = Int(text[offset + 3]);
        let second_valid -> Bool = second >= 128 && second <= 191;
        if (first == 240) { second_valid = second >= 144 && second <= 191; }
        if (first == 244) { second_valid = second >= 128 && second <= 143; }
        if (second_valid &&
            third >= 128 && third <= 191 &&
            fourth >= 128 && fourth <= 191) {
            return __SourceUnit(
                scalar=((first & 7) << 18) |
                       ((second & 63) << 12) |
                       ((third & 63) << 6) |
                       (fourth & 63),
                width=4,
                valid=true
            );
        }
    }

    return __SourceUnit(scalar=65533, width=1, valid=false);
}

func source_position(text -> String, line -> Int, byte_column -> Int) -> SourcePosition {
    let target_line -> Int = line;
    if (target_line < 0) { target_line = 0; }
    if (text is null) {
        return SourcePosition(
            byte_offset=0,
            line=target_line,
            byte_column=0,
            unicode_column=0,
            utf16_column=0
        );
    }

    let line_start -> Int = 0;
    let current_line -> Int = 0;
    while (line_start < text.length() && current_line < target_line) {
        if (text[line_start] == '\n') { current_line += 1; }
        line_start += 1;
    }

    let line_end -> Int = line_start;
    while (line_end < text.length() &&
           text[line_end] != '\n' &&
           text[line_end] != '\r') {
        line_end += 1;
    }

    let column -> Int = byte_column;
    if (column < 0) { column = 0; }
    let line_bytes -> Int = line_end - line_start;
    if (column > line_bytes) { column = line_bytes; }

    let target -> Int = line_start + column;
    let offset -> Int = line_start;
    let unicode_column -> Int = 0;
    let utf16_column -> Int = 0;
    while (offset < target) {
        let unit -> __SourceUnit = __source_unit(text, offset);
        let width -> Int = unit.width;
        if (width <= 0 || offset + width > target) { break; }
        offset += width;
        unicode_column += 1;
        if (unit.scalar > 65535) {
            utf16_column += 2;
        } else {
            utf16_column += 1;
        }
    }

    return SourcePosition(
        byte_offset=line_start + column,
        line=current_line,
        byte_column=column,
        unicode_column=unicode_column,
        utf16_column=utf16_column
    );
}

func source_range(file -> String, text -> String, line -> Int, byte_column -> Int, byte_width -> Int) -> SourceRange {
    let width -> Int = byte_width;
    if (width < 0) { width = 0; }
    return SourceRange(
        file=file,
        start=source_position(text, line, byte_column),
        end=source_position(text, line, byte_column + width)
    );
}

func __diagnostic_width(pos -> Position) -> Int {
    let offset -> Int = source_position(pos.text, pos.ln, pos.col).byte_offset;
    if (offset < 0 || offset >= pos.text.length()) { return 1; }

    let first -> Int = Int(pos.text[offset]);
    let identifier -> Bool =
        (first >= Int('a') && first <= Int('z')) ||
        (first >= Int('A') && first <= Int('Z')) ||
        (first >= Int('0') && first <= Int('9')) ||
        first == Int('_');
    if (!identifier) {
        let unit -> __SourceUnit = __source_unit(pos.text, offset);
        if (unit.width > 0) { return unit.width; }
        return 1;
    }

    let end -> Int = offset;
    while (end < pos.text.length()) {
        let current -> Int = Int(pos.text[end]);
        let valid -> Bool =
            (current >= Int('a') && current <= Int('z')) ||
            (current >= Int('A') && current <= Int('Z')) ||
            (current >= Int('0') && current <= Int('9')) ||
            current == Int('_');
        if (!valid) { break; }
        end += 1;
    }
    return end - offset;
}

func diagnostic_code(category -> String) -> String {
    if (category == "IllegalCharacter") { return "E0001"; }
    if (category == "InvalidSyntax") { return "E1001"; }
    if (category == "NameError") { return "E2001"; }
    if (category == "TypeError") { return "E3001"; }
    if (category == "MissingInitializer") { return "E3002"; }
    if (category == "NullDereferenceError") { return "E4001"; }
    if (category == "IndexError") { return "E4002"; }
    if (category == "ImportError") { return "E5001"; }
    if (category == "InternalCompilerError") { return "E6001"; }
    if (category == "ZeroDivisionError") { return "E7001"; }
    if (category == "OverflowError") { return "E7002"; }
    if (category == "ExternError") { return "E8001"; }
    return "E0000";
}

func reset_errors() -> Void {
    GLOBAL_ERROR_COUNT = 0;
    LAST_ERROR_FILE = "";
    ERROR_BUFFER = [];
    REPORTED_ERRORS = null;
    STRUCTURED_ERRORS = [];
}

func begin_error_collection() -> Void {
    reset_errors();
    COLLECT_ERRORS_ONLY = true;
}

func end_error_collection() -> Void {
    COLLECT_ERRORS_ONLY = false;
}

func advance_pos(pos -> Position, current_char -> Char) -> Void {
    pos.idx = pos.idx + 1;
    pos.col = pos.col + 1;

    if (current_char == '\n') {
        pos.ln = pos.ln + 1;
        pos.col = 0;
    }
}

func abort_and_clean(status -> Int) -> Void {
    if (ACTIVE_FILE is !null) {
        ACTIVE_FILE.close();
    }
    if (CLEAN_TMP_LL.length() > 0) {
        file.remove(CLEAN_TMP_LL)?;
        catch(err) { }
    }
    process.exit(status);
}

func report_error(pos -> Position, name -> String, details -> String) -> Void {
    if (COLLECT_ERRORS_ONLY && GLOBAL_ERROR_COUNT >= 50) { return; }
    let error_key -> String = pos.fn + ":" + pos.ln + ":" + pos.col + ":" + name + ":" + details;
    if (REPORTED_ERRORS is null) { REPORTED_ERRORS = Dict(); }
    if (REPORTED_ERRORS.contains_key(error_key)) { return; }
    REPORTED_ERRORS.put(error_key, true);

    GLOBAL_ERROR_COUNT = GLOBAL_ERROR_COUNT + 1;
    if (STRUCTURED_ERRORS is null) { STRUCTURED_ERRORS = []; }
    let range -> SourceRange =
        source_range(pos.fn, pos.text, pos.ln, pos.col, __diagnostic_width(pos));
    STRUCTURED_ERRORS.append(CompilerDiagnostic(
        code=diagnostic_code(name),
        severity=DIAGNOSTIC_ERROR,
        category=name,
        message=details,
        pos=pos,
        range=range,
        notes=[]
    ));

    let ln -> Int = pos.ln + 1;
    let col -> Int = pos.col + 1;

    if (ERROR_BUFFER is null) { ERROR_BUFFER = []; }
    let err_msg -> String = "";

    if (LAST_ERROR_FILE != pos.fn) {
        err_msg += "In file:\n";
    }
    err_msg += "   " + pos.fn + ":" + ln + ":" + col + "\n   | \n";
    LAST_ERROR_FILE = pos.fn;

    let text -> String = pos.text;
    let target_ln -> Int = pos.ln;
    let current_ln -> Int = 0;
    let start_idx -> Int = 0;
    let i -> Int = 0;

    while (i < text.length() && current_ln < target_ln) {
        if (text[i] == '\n') { // '\n'
            current_ln += 1;
            start_idx = i + 1;
        }
        i += 1;
    }

    let end_idx -> Int = start_idx;
    while (end_idx < text.length() && text[end_idx] != '\n' && text[end_idx] != '\r') {
        end_idx += 1;
    }

    if (start_idx < text.length()) {
        let line_text -> String = text.slice(start_idx, end_idx);
        
        let ln_str -> String = "" + ln;
        let ln_width -> Int = ln_str.length();
        
        let empty_prefix -> String = "  ";
        let p1 -> Int = 0;
        while (p1 < ln_width) { empty_prefix = empty_prefix + " "; p1 += 1; }
        
        err_msg += " " + ln_str + " | " + line_text + "\n";

        let err_len -> Int =
            range.end.unicode_column - range.start.unicode_column;
        if (err_len < 1) { err_len = 1; }
        let line_len -> Int = line_text.length();

        let caret_line -> String = empty_prefix + "| ";
        let j -> Int = 0;
        while (j < pos.col) {
            let unit -> __SourceUnit = __source_unit(line_text, j);
            let width -> Int = unit.width;
            if (width <= 0) { break; }
            if (Int(line_text[j]) == Int('\t')) {
                caret_line += "\t";
            } else {
                caret_line += " ";
            }
            j += width;
        }
        
        let k -> Int = 0;
        while (k < err_len) {
            caret_line = caret_line + "^";
            k += 1;
        }
        
        err_msg += caret_line + "\n";
    }

    err_msg += name + ": " + details + "\n\n";
    ERROR_BUFFER.append(err_msg);

    if (GLOBAL_ERROR_COUNT > 50 && !COLLECT_ERRORS_ONLY) {
        ERROR_BUFFER.append("fatal error: too many errors emitted, stopping now\n");
        check_errors_and_abort();
    }
}

func throw_illegal_char(pos -> Position, details -> String) -> Void {
    report_error(pos, "IllegalCharacter", details);
}

func throw_invalid_syntax(pos -> Position, details -> String) -> Void {
    report_error(pos, "InvalidSyntax", details);
}

func throw_name_error(pos -> Position, details -> String) -> Void {
    report_error(pos, "NameError", details);
}

func throw_type_error(pos -> Position, details -> String) -> Void {
    report_error(pos, "TypeError", details);
}

func throw_missing_initializer(pos -> Position, details -> String) -> Void {
    report_error(pos, "MissingInitializer", details);
}

func throw_null_dereference_error(pos -> Position, details -> String) -> Void {
    report_error(pos, "NullDereferenceError", details);
}

func throw_index_error(pos -> Position, details -> String) -> Void {
    report_error(pos, "IndexError", details);
}

func throw_import_error(pos -> Position, details -> String) -> Void {
    report_error(pos, "ImportError", details);
}

func throw_internal_compiler_error(pos -> Position, details -> String) -> Void {
    if (pos is null) {
        print("InternalCompilerError: " + details);
        abort_and_clean(1);
        return;
    }
    report_error(pos, "InternalCompilerError", details);
}

func throw_zero_division_error(pos -> Position, details -> String) -> Void {
    report_error(pos, "ZeroDivisionError", details);
}

func throw_overflow_error(pos -> Position, details -> String) -> Void {
    report_error(pos, "OverflowError", details);
}

func throw_extern_error(pos -> Position, details -> String) -> Void {
    report_error(pos, "ExternError", details);
}

func throw_missing_main_function() -> Void { // special
    print("MissingMainFunction: No 'main' function defined.");
    abort_and_clean(1);
}

func throw_environment_error(details -> String) -> Void { // special
    print("EnvironmentError: " + details);
    abort_and_clean(1);
}

func check_errors_and_abort() -> Void {
    if (GLOBAL_ERROR_COUNT > 0) {
        let i -> Int = 0;
        let buf_len -> Int = 0;
        if (ERROR_BUFFER is !null) { buf_len = ERROR_BUFFER.length(); }
        while (i < buf_len) {
            print(ERROR_BUFFER[i]);
            i += 1;
        }

        let suffix -> String = " error.\n";
        if (GLOBAL_ERROR_COUNT > 1) { suffix = " errors.\n"; }
        print("Found " + GLOBAL_ERROR_COUNT + suffix);
        abort_and_clean(1);
    }
}
