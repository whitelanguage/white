// frontend/lexer.wl
import "tokens.wl" as WhitelangTokens
import * from "tokens.wl"
import * from "diagnostics.wl"

struct Lexer(
    text: String,
    length: Int,
    pos: Position,
    current_char: Char,
    current_width: Int,
    current_valid: Bool,
    collect_trivia: Bool,
    trivia: Vector(Struct)
)

struct Utf8Unit(
    value: Char,
    width: Int,
    valid: Bool
)

const TRIVIA_LINE_COMMENT: Int = 1;
const TRIVIA_BLOCK_COMMENT: Int = 2;

struct LexerTrivia(
    kind: Int,
    start_line: Int,
    start_col: Int,
    end_line: Int,
    end_col: Int
)

func is_space(c: Char) -> Bool {
    return (c == ' ') || (c == '\t') || (c == '\n') || (c == '\r');
}

func is_digit(c: Char) -> Bool {
    return (c >= '0') && (c <= '9');
}

func is_alpha(c: Char) -> Bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c == '_');
}

func decode_utf8_unit(text: String, offset: Int) -> Utf8Unit {
    // lexer offsets remain byte based even though current_char is a Unicode scalar
    if (offset < 0 || offset >= text.length()) {
        return Utf8Unit(value='\0', width=0, valid=true);
    }

    let first: Int = Int(text[offset]);
    if (first <= 127) {
        return Utf8Unit(value=Char(first), width=1, valid=true);
    }

    if (first >= 194 && first <= 223 && offset + 1 < text.length()) {
        let second: Int = Int(text[offset + 1]);
        if (second >= 128 && second <= 191) {
            let scalar: Int = ((first & 31) << 6) | (second & 63);
            return Utf8Unit(value=Char(scalar), width=2, valid=true);
        }
    }

    if (first >= 224 && first <= 239 && offset + 2 < text.length()) {
        let second: Int = Int(text[offset + 1]);
        let third: Int = Int(text[offset + 2]);
        let second_valid: Bool = second >= 128 && second <= 191;
        if (first == 224) { second_valid = second >= 160 && second <= 191; }
        if (first == 237) { second_valid = second >= 128 && second <= 159; }
        if (second_valid && third >= 128 && third <= 191) {
            let scalar: Int =
                ((first & 15) << 12) | ((second & 63) << 6) | (third & 63);
            return Utf8Unit(value=Char(scalar), width=3, valid=true);
        }
    }

    if (first >= 240 && first <= 244 && offset + 3 < text.length()) {
        let second: Int = Int(text[offset + 1]);
        let third: Int = Int(text[offset + 2]);
        let fourth: Int = Int(text[offset + 3]);
        let second_valid: Bool = second >= 128 && second <= 191;
        if (first == 240) { second_valid = second >= 144 && second <= 191; }
        if (first == 244) { second_valid = second >= 128 && second <= 143; }
        if (second_valid &&
            third >= 128 && third <= 191 &&
            fourth >= 128 && fourth <= 191) {
            let scalar: Int =
                ((first & 7) << 18) |
                ((second & 63) << 12) |
                ((third & 63) << 6) |
                (fourth & 63);
            return Utf8Unit(value=Char(scalar), width=4, valid=true);
        }
    }

    return Utf8Unit(value=Char(65533), width=1, valid=false);
}

func is_digit_for_base(c: Char, base: Int) -> Bool {
    if (c >= '0' && c <= '9') {
        return Int(c) - Int('0') < base;
    }
    if (base == 16) {
        return (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
    }
    return false;
}

func report_bad_number(l: Lexer, line: Int, col: Int, value: String) -> Void {
    let pos: Position = Position(idx=0, ln=line, col=col, text=l.text, fn=l.pos.fn);
    throw_invalid_syntax(pos, "Invalid numeric literal '" + value + "'.");
}

func validate_number(l: Lexer, line: Int, col: Int, value: String, is_float: Bool) -> Bool {
    if (value.length() == 0) { return false; }

    let end: Int = value.length();
    if is_float {
        if (value.ends_with("f") || value.ends_with("F")) { end -= 1; }
        if (end == 0) {
            report_bad_number(l, line, col, value);
            return false;
        }

        let dot_seen: Bool = false;
        let digit_seen: Bool = false;
        let prev_digit: Bool = false;
        let i: Int = 0;
        while (i < end) {
            let ch: Char = value[i];
            if (is_digit(ch)) {
                digit_seen = true;
                prev_digit = true;
            } else if (ch == '.') {
                if dot_seen {
                    report_bad_number(l, line, col, value);
                    return false;
                }
                dot_seen = true;
                prev_digit = false;
            } else if (ch == '_') {
                if (!prev_digit || i + 1 >= end || !is_digit(value[i + 1])) {
                    report_bad_number(l, line, col, value);
                    return false;
                }
                prev_digit = false;
            } else {
                report_bad_number(l, line, col, value);
                return false;
            }
            i += 1;
        }

        if (!dot_seen || !digit_seen) {
            report_bad_number(l, line, col, value);
            return false;
        }
        return true;
    }

    let suffix_len: Int = 0;
    if (value.ends_with("ULL") || value.ends_with("ull")) {
        suffix_len = 3;
    } else if (value.ends_with("LL") || value.ends_with("ll") ||
               value.ends_with("UL") || value.ends_with("ul")) {
        suffix_len = 2;
    } else if (value.ends_with("U") || value.ends_with("u") ||
               value.ends_with("L") || value.ends_with("l")) {
        suffix_len = 1;
    }

    end -= suffix_len;
    let base: Int = 10;
    let start: Int = 0;
    if (end >= 2 && value[0] == '0') {
        let prefix: Char = value[1];
        if (prefix == 'x' || prefix == 'X') { base = 16; start = 2; }
        else if (prefix == 'b' || prefix == 'B') { base = 2; start = 2; }
        else if (prefix == 'o' || prefix == 'O') { base = 8; start = 2; }
    }

    if (start >= end) {
        report_bad_number(l, line, col, value);
        return false;
    }

    let prev_digit: Bool = false;
    let i: Int = start;
    while (i < end) {
        let ch: Char = value[i];
        if (is_digit_for_base(ch, base)) {
            prev_digit = true;
        } else if (ch == '_') {
            if (!prev_digit || i + 1 >= end || !is_digit_for_base(value[i + 1], base)) {
                report_bad_number(l, line, col, value);
                return false;
            }
            prev_digit = false;
        } else {
            report_bad_number(l, line, col, value);
            return false;
        }
        i += 1;
    }
    return true;
}

func lexer_load_current(l: Lexer) -> Void {
    while (l.pos.idx < l.length) {
        let first: Int = Int(l.text[l.pos.idx]);
        if (first > 0 && first <= 127) {
            l.current_char = Char(first);
            l.current_width = 1;
            l.current_valid = true;
            return;
        }
        let unit: Utf8Unit = decode_utf8_unit(l.text, l.pos.idx);
        if (!unit.valid || unit.value == '\0') {
            let err_pos: Position = Position(idx=l.pos.idx, ln=l.pos.ln, col=l.pos.col, text=l.text, fn=l.pos.fn);
            if (!unit.valid) { throw_illegal_char(err_pos, "Invalid UTF-8 byte in source."); }
            else { throw_illegal_char(err_pos, "NUL byte is not allowed in source."); }
            let width: Int = unit.width;
            if (width <= 0) { width = 1; }
            l.pos.idx += width;
            l.pos.col += width;
            continue;
        }
        l.current_char = unit.value;
        l.current_width = unit.width;
        l.current_valid = true;
        return;
    }
    l.current_char = '\0';
    l.current_width = 0;
    l.current_valid = true;
}

func __new_lexer(fn: String, text: String, collect_trivia: Bool) -> Lexer {
    let pos: Position = Position(idx=0, ln=0, col=0, text=text, fn=fn);
    let l: Lexer = Lexer(text=text, length=text.length(), pos=pos, current_char='\0', current_width=0, current_valid=true, collect_trivia=collect_trivia, trivia=[]);
    lexer_load_current(l);
    return l;
}

func new_lexer(fn: String, text: String) -> Lexer {
    return __new_lexer(fn, text, false);
}

func new_lexer_trivia(fn: String, text: String) -> Lexer {
    return __new_lexer(fn, text, true);
}

func lexer_advance(l: Lexer) -> Void {
    if (l.current_char == '\0') { return; }
    let previous_width: Int = l.current_width;
    if (l.current_char == '\n') {
        l.pos.ln += 1;
        l.pos.col = 0;
    } else {
        l.pos.col += previous_width;
    }
    l.pos.idx += previous_width;

    if (l.pos.idx < l.length) {
        let next: Int = Int(l.text[l.pos.idx]);
        if (next > 0 && next <= 127) {
            l.current_char = Char(next);
            l.current_width = 1;
            l.current_valid = true;
            return;
        }
    }
    lexer_load_current(l);
}

func get_string(l: Lexer) -> Token {
    let start_ln: Int = l.pos.ln;
    let start_col: Int = l.pos.col;
    lexer_advance(l);

    let result: String = "";
    let chunk_start: Int = l.pos.idx;
    while (l.current_char != '"' && l.current_char != '\0') {
        if (l.current_char == '\\') {
            if (l.pos.idx > chunk_start) {
                result += l.text.slice(chunk_start, l.pos.idx);
            }
            lexer_advance(l);
            if (l.current_char == 'n') {
                result += "\n";
            } else if (l.current_char == 't') {
                result += "\t";
            } else if (l.current_char == 'r') {
                result += "\r";
            } else if (l.current_char == '"') {
                result += "\"";
            } else if (l.current_char == '\\') {
                result += "\\";
            } else {
                let idx: Int = l.pos.idx;
                result += l.text.slice(idx, idx + l.current_width);
            }
            lexer_advance(l);
            chunk_start = l.pos.idx;
        } else {
            lexer_advance(l);
        }
    }

    if (l.current_char == '"') {
        if (l.pos.idx > chunk_start) {
            result += l.text.slice(chunk_start, l.pos.idx);
        }
        lexer_advance(l);
        return WhitelangTokens.Token(type=TOK_STR_LIT, value=result, line=start_ln, col=start_col);
    }

    if (l.pos.idx > chunk_start) {
        result += l.text.slice(chunk_start, l.pos.idx);
    }
    throw_illegal_char(l.pos, "Unterminated string literal. ");
    return WhitelangTokens.Token(type=TOK_STR_LIT, value=result, line=start_ln, col=start_col);
}

func get_char_literal(l: Lexer) -> Token {
    let start_ln: Int = l.pos.ln;
    let start_col: Int = l.pos.col;
    
    lexer_advance(l); // skip opening '
    let char_val: Int = 0;
    
    if (l.current_char == '\\') { // '\'
        lexer_advance(l);
        if (l.current_char == 'n') { char_val = 10; } // \n
        else if (l.current_char == 't') { char_val = 9; } // \t
        else if (l.current_char == 'r') { char_val = 13; } // \r
        else if (l.current_char == '0') { char_val = 0; } // \0
        else if (l.current_char == '\\') { char_val = 92; } // \\
        else if (l.current_char == '\'') { char_val = 39; } // \'
        else { char_val = Int(l.current_char); }
        lexer_advance(l);
    } else {
        char_val = Int(l.current_char);
        lexer_advance(l);
    }
    
    if (l.current_char == '\'') {
        lexer_advance(l); // skip closing '
    } else {
        throw_illegal_char(l.pos, "Unterminated char literal.");
    }

    return WhitelangTokens.Token(type=TOK_CHAR_LIT, value="" + char_val, line=start_ln, col=start_col);
}


func get_number(l: Lexer) -> Token {
    let start_line: Int = l.pos.ln;
    let start_col: Int = l.pos.col;
    let start_pos: Int = l.pos.idx;
    
    let dot_count: Int = 0;
    while (l.current_char != '\0') {
        if (l.current_char == '.') {
            if (dot_count == 1) { break; }
            dot_count = 1;
            lexer_advance(l);
            continue;
        }
        if (is_digit(l.current_char) || is_alpha(l.current_char)) {
            lexer_advance(l);
        } else {
            break;
        }
    }
    
    let value: String = l.text.slice(start_pos, l.pos.idx);

    if (value.length() > 0) {
        if (value[0] == '.') {
            value = "0" + value;
        }
    }

    if (dot_count == 1) {
        validate_number(l, start_line, start_col, value, true);
        return WhitelangTokens.Token(type=TOK_FLOAT, value=value, line=start_line, col=start_col);
    }
    validate_number(l, start_line, start_col, value, false);
    return WhitelangTokens.Token(type=TOK_INT, value=value, line=start_line, col=start_col);
}

func keyword_matches(text: String, start: Int, length: Int, keyword: String) -> Bool {
    if (length != keyword.length()) { return false; }
    let i: Int = 0;
    while (i < length) {
        if (text[start + i] != keyword[i]) { return false; }
        i += 1;
    }
    return true;
}

func keyword_type(text: String, start: Int, length: Int) -> Int {
    let first: Char = text[start];
    if (length == 2) {
        if (first == 'a') {
            if (keyword_matches(text, start, length, "as")) { return TOK_AS; }
        } else if (first == 'i') {
            if (keyword_matches(text, start, length, "if")) { return TOK_IF; }
            if (keyword_matches(text, start, length, "is")) { return TOK_IS; }
            if (keyword_matches(text, start, length, "in")) { return TOK_IN; }
        }
    } else if (length == 3) {
        if (first == 'I') {
            if (keyword_matches(text, start, length, "Int")) { return TOK_T_INT; }
        } else if (first == 'f') {
            if (keyword_matches(text, start, length, "for")) { return TOK_FOR; }
        } else if (first == 'l') {
            if (keyword_matches(text, start, length, "let")) { return TOK_LET; }
        } else if (first == 'p') {
            if (keyword_matches(text, start, length, "ptr")) { return TOK_PTR; }
        } else if (first == 'r') {
            if (keyword_matches(text, start, length, "ref")) { return TOK_REF; }
        }
    } else if (length == 4) {
        if (first == 'B') {
            if (keyword_matches(text, start, length, "Bool")) { return TOK_T_BOOL; }
        } else if (first == 'C') {
            if (keyword_matches(text, start, length, "Char")) { return TOK_T_CHAR; }
        } else if (first == 'V') {
            if (keyword_matches(text, start, length, "Void")) { return TOK_T_VOID; }
        } else if (first == 'e') {
            if (keyword_matches(text, start, length, "else")) { return TOK_ELSE; }
            if (keyword_matches(text, start, length, "enum")) { return TOK_ENUM; }
        } else if (first == 'f') {
            if (keyword_matches(text, start, length, "func")) { return TOK_FUNC; }
            if (keyword_matches(text, start, length, "from")) { return TOK_FROM; }
        } else if (first == 'n') {
            if (keyword_matches(text, start, length, "null")) { return TOK_NULL; }
        } else if (first == 's') {
            if (keyword_matches(text, start, length, "self")) { return TOK_SELF; }
        } else if (first == 't') {
            if (keyword_matches(text, start, length, "true")) { return TOK_TRUE; }
            if (keyword_matches(text, start, length, "this")) { return TOK_THIS; }
            if (keyword_matches(text, start, length, "type")) { return TOK_TYPE; }
        } else if (first == 'w') {
            if (keyword_matches(text, start, length, "with")) { return TOK_WITH; }
        }
    } else if (length == 5) {
        if (first == 'F') {
            if (keyword_matches(text, start, length, "Float")) { return TOK_T_FLOAT; }
        } else if (first == 'b') {
            if (keyword_matches(text, start, length, "break")) { return TOK_BREAK; }
        } else if (first == 'c') {
            if (keyword_matches(text, start, length, "const")) { return TOK_CONST; }
            if (keyword_matches(text, start, length, "class")) { return TOK_CLASS; }
            if (keyword_matches(text, start, length, "catch")) { return TOK_CATCH; }
        } else if (first == 'd') {
            if (keyword_matches(text, start, length, "deref")) { return TOK_DEREF; }
        } else if (first == 'e') {
            if (keyword_matches(text, start, length, "error")) { return TOK_ERROR; }
        } else if (first == 'f') {
            if (keyword_matches(text, start, length, "false")) { return TOK_FALSE; }
        } else if (first == 's') {
            if (keyword_matches(text, start, length, "super")) { return TOK_SUPER; }
        } else if (first == 't') {
            if (keyword_matches(text, start, length, "throw")) { return TOK_THROW; }
        } else if (first == 'w') {
            if (keyword_matches(text, start, length, "while")) { return TOK_WHILE; }
        }
    } else if (length == 6) {
        if (first == 'S') {
            if (keyword_matches(text, start, length, "String")) { return TOK_T_STRING; }
        } else if (first == 'e') {
            if (keyword_matches(text, start, length, "extern")) { return TOK_EXTERN; }
        } else if (first == 'i') {
            if (keyword_matches(text, start, length, "import")) { return TOK_IMPORT; }
        } else if (first == 'm') {
            if (keyword_matches(text, start, length, "method")) { return TOK_METHOD; }
        } else if (first == 'r') {
            if (keyword_matches(text, start, length, "return")) { return TOK_RETURN; }
        } else if (first == 's') {
            if (keyword_matches(text, start, length, "struct")) { return TOK_STRUCT; }
        }
    } else if (length == 7) {
        if (first == 'n' && keyword_matches(text, start, length, "nullptr")) { return TOK_NULLPTR; }
    } else if (length == 8) {
        if (first == 'c' && keyword_matches(text, start, length, "continue")) { return TOK_CONTINUE; }
    } else if (length == 9 && first == 'i' && keyword_matches(text, start, length, "interface")) {
        return TOK_INTERFACE;
    }
    return TOK_IDENTIFIER;
}

func get_identifier(l: Lexer) -> Token {
    let start_line: Int = l.pos.ln;
    let start_col: Int = l.pos.col;
    let start_pos: Int = l.pos.idx;
    while (l.current_char != '\0' && (is_alpha(l.current_char) || is_digit(l.current_char))) {
        lexer_advance(l);
    }
    let length: Int = l.pos.idx - start_pos;
    let type: Int = keyword_type(l.text, start_pos, length);
    if (type != TOK_IDENTIFIER) {
        return WhitelangTokens.Token(type=type, value=get_token_name(type), line=start_line, col=start_col);
    }
    let value: String = l.text.slice(start_pos, l.pos.idx);
    return WhitelangTokens.Token(type=type, value=value, line=start_line, col=start_col);
}


func handle_slash(l: Lexer) -> Token {
    let line: Int = l.pos.ln;
    let col: Int = l.pos.col;
    lexer_advance(l); // skip first /

    // /=
    if (l.current_char == '=') {
        lexer_advance(l);
        return WhitelangTokens.Token(type=TOK_DIV_ASSIGN, value="/=", line=line, col=col);
    }

    // //
    if (l.current_char == '/') {
        while (l.current_char != '\0' && l.current_char != '\n') { lexer_advance(l); }
        if (l.collect_trivia) {
            l.trivia.append(LexerTrivia(
                kind=TRIVIA_LINE_COMMENT,
                start_line=line,
                start_col=col,
                end_line=l.pos.ln,
                end_col=l.pos.col
            ));
        }
        return Token();
    }

    // /*  */
    if (l.current_char == '*') {
        lexer_advance(l);
        let comment_closed: Int = 0;
        while (l.current_char != '\0' && comment_closed == 0) {
            if (l.current_char == '*') {
                lexer_advance(l);
                if (l.current_char == '/') {
                    lexer_advance(l);
                    comment_closed = 1;
                }
            } else { lexer_advance(l); }
        }
        if (comment_closed == 0) { throw_illegal_char(l.pos, "Unterminated block comment."); }
        if (l.collect_trivia) {
            l.trivia.append(LexerTrivia(
                kind=TRIVIA_BLOCK_COMMENT,
                start_line=line,
                start_col=col,
                end_line=l.pos.ln,
                end_col=l.pos.col
            ));
        }
        return Token();
    }

    return WhitelangTokens.Token(type=TOK_DIV, value="/", line=line, col=col);
}


func get_next_token(l: Lexer) -> Token {
    while (l.current_char != '\0') {
        if (!l.current_valid) {
            throw_illegal_char(l.pos, "Invalid UTF-8 byte in source.");
            lexer_advance(l);
            continue;
        }
        if (is_space(l.current_char)) {
            lexer_advance(l);
            continue;
        }

        if (is_digit(l.current_char)) {
            return get_number(l);
        }

        if (is_alpha(l.current_char)) {
            return get_identifier(l);
        }

        let char: Char = l.current_char;
        let char_line: Int  = l.pos.ln;
        let char_col: Int  = l.pos.col;

        if (char == '"') {
            return get_string(l);
        }
        if (char == '\'') {
            return get_char_literal(l);
        }

        // . and ...
        if (char == '.') {
            let is_ellipsis: Bool = false;
            if (l.pos.idx + 2 < l.length) {
                let n1: Char = l.text[l.pos.idx + 1];
                let n2: Char = l.text[l.pos.idx + 2];
                if (n1 == '.' && n2 == '.') { // . .
                    is_ellipsis = true;
                }
            }

            if is_ellipsis {
                lexer_advance(l); lexer_advance(l); lexer_advance(l); // consume ...
                return WhitelangTokens.Token(type=TOK_ELLIPSIS, value="...", line=char_line, col=char_col);
            } else {
                lexer_advance(l);
                return WhitelangTokens.Token(type=TOK_DOT, value=".", line=char_line, col=char_col);
            }
        }

        // + and ++ and +=
        if (char == '+') { 
            lexer_advance(l);
            if (l.current_char == '=') { lexer_advance(l); return WhitelangTokens.Token(type=TOK_PLUS_ASSIGN, value="+=", line=char_line, col=char_col); } // +=
            if (l.current_char == '+') { lexer_advance(l); return WhitelangTokens.Token(type=TOK_INC, value="++", line=char_line, col=char_col); } // ++
            return WhitelangTokens.Token(type=TOK_PLUS, value="+", line=char_line, col=char_col); 
        }

        // - and -- and: and -=
        if (char == '-') { 
            lexer_advance(l); 
            if (l.current_char == '=') { lexer_advance(l); return WhitelangTokens.Token(type=TOK_SUB_ASSIGN, value="-=", line=char_line, col=char_col); } // -=
            if (l.current_char == '>') { lexer_advance(l); return WhitelangTokens.Token(type=TOK_TYPE_ARROW, value="->", line=char_line, col=char_col); } // ->
            if (l.current_char == '-') { lexer_advance(l); return WhitelangTokens.Token(type=TOK_DEC, value="--", line=char_line, col=char_col); } // --
            return WhitelangTokens.Token(type=TOK_SUB, value="-", line=char_line, col=char_col); 
        }

        // * *= ** **=
        if (char == '*') { 
            lexer_advance(l); 
            if (l.current_char == '=') { lexer_advance(l); return WhitelangTokens.Token(type=TOK_MUL_ASSIGN, value="*=", line=char_line, col=char_col); } // *=
            if (l.current_char == '*') { 
                lexer_advance(l); 
                if (l.current_char == '=') { lexer_advance(l); return WhitelangTokens.Token(type=TOK_POW_ASSIGN, value="**=", line=char_line, col=char_col); } // **=
                return WhitelangTokens.Token(type=TOK_POW, value="**", line=char_line, col=char_col); // **
            }
            return WhitelangTokens.Token(type=TOK_MUL, value="*", line=char_line, col=char_col); 
        }

        // / /= // /*
        if (char == '/') {
            let tok: Token = handle_slash(l);
            if (tok.type == 0) { continue; }
            return tok;
        }

        if (char == '%') { 
            lexer_advance(l); 
            if (l.current_char == '=') { lexer_advance(l); return WhitelangTokens.Token(type=TOK_MOD_ASSIGN, value="%=", line=char_line, col=char_col); } // %=
            return WhitelangTokens.Token(type=TOK_MOD, value="%", line=char_line, col=char_col); 
        }

        // ! and !=
        if (char == '!') {
            lexer_advance(l);
            if (l.current_char == '=') { lexer_advance(l); return WhitelangTokens.Token(type=TOK_NE, value="!=", line=char_line, col=char_col); }
            return WhitelangTokens.Token(type=TOK_NOT, value="!", line=char_line, col=char_col);
        }

        // = and ==
        if (char == '=') {
            lexer_advance(l);
            if (l.current_char == '=') { lexer_advance(l); return WhitelangTokens.Token(type=TOK_EE, value="==", line=char_line, col=char_col); }
            return WhitelangTokens.Token(type=TOK_ASSIGN, value="=", line=char_line, col=char_col);
        }

        // <, <=, <<, <<=
        if (char == '<') {
            lexer_advance(l);
            if (l.current_char == '=') { lexer_advance(l); return WhitelangTokens.Token(type=TOK_LTE, value="<=", line=char_line, col=char_col); }
            if (l.current_char == '<') { // <<
                lexer_advance(l);
                if (l.current_char == '=') { lexer_advance(l); return WhitelangTokens.Token(type=TOK_LSHIFT_ASSIGN, value="<<=", line=char_line, col=char_col); }
                return WhitelangTokens.Token(type=TOK_LSHIFT, value="<<", line=char_line, col=char_col);
            }
            return WhitelangTokens.Token(type=TOK_LT, value="<", line=char_line, col=char_col);
        }

        // >, >=, >>, >>=
        if (char == '>') {
            lexer_advance(l);
            if (l.current_char == '=') { lexer_advance(l); return WhitelangTokens.Token(type=TOK_GTE, value=">=", line=char_line, col=char_col); }
            if (l.current_char == '>') { // >>
                lexer_advance(l);
                if (l.current_char == '=') { lexer_advance(l); return WhitelangTokens.Token(type=TOK_RSHIFT_ASSIGN, value=">>=", line=char_line, col=char_col); }
                return WhitelangTokens.Token(type=TOK_RSHIFT, value=">>", line=char_line, col=char_col);
            }
            return WhitelangTokens.Token(type=TOK_GT, value=">", line=char_line, col=char_col);
        }

        // &, &&, &=
        if (char == '&') {
            lexer_advance(l);
            if (l.current_char == '&') { lexer_advance(l); return WhitelangTokens.Token(type=TOK_AND, value="&&", line=char_line, col=char_col); }
            if (l.current_char == '=') { lexer_advance(l); return WhitelangTokens.Token(type=TOK_BIT_AND_ASSIGN, value="&=", line=char_line, col=char_col); }
            return WhitelangTokens.Token(type=TOK_BIT_AND, value="&", line=char_line, col=char_col);
        }

        // |, ||, |=
        if (char == '|') {
            lexer_advance(l);
            if (l.current_char == '|') { lexer_advance(l); return WhitelangTokens.Token(type=TOK_OR, value="||", line=char_line, col=char_col); }
            if (l.current_char == '=') { lexer_advance(l); return WhitelangTokens.Token(type=TOK_BIT_OR_ASSIGN, value="|=", line=char_line, col=char_col); }
            return WhitelangTokens.Token(type=TOK_BIT_OR, value="|", line=char_line, col=char_col);
        }

        // ^, ^=
        if (char == '^') {
            lexer_advance(l);
            if (l.current_char == '=') { lexer_advance(l); return WhitelangTokens.Token(type=TOK_BIT_XOR_ASSIGN, value="^=", line=char_line, col=char_col); }
            return WhitelangTokens.Token(type=TOK_BIT_XOR, value="^", line=char_line, col=char_col);
        }

        // ~
        if (char == '~') {
            lexer_advance(l);
            return WhitelangTokens.Token(type=TOK_BIT_NOT, value="~", line=char_line, col=char_col);
        }

        // @
        if (char == '@') {
            lexer_advance(l);
            return WhitelangTokens.Token(type=TOK_AT, value="@", line=char_line, col=char_col);
        }

        // Single char tokens
        if (char == '(') { lexer_advance(l);  return WhitelangTokens.Token(type=TOK_LPAREN,   value="(", line=char_line, col=char_col); }
        if (char == ')') { lexer_advance(l);  return WhitelangTokens.Token(type=TOK_RPAREN,   value=")", line=char_line, col=char_col); }
        if (char == ';') { lexer_advance(l);  return WhitelangTokens.Token(type=TOK_SEMICOLON,value=";", line=char_line, col=char_col); }
        if (char == '{') { lexer_advance(l); return WhitelangTokens.Token(type=TOK_LBRACE,   value="{", line=char_line, col=char_col); }
        if (char == '}') { lexer_advance(l); return WhitelangTokens.Token(type=TOK_RBRACE,   value="}", line=char_line, col=char_col); }
        if (char == ',') { lexer_advance(l);  return WhitelangTokens.Token(type=TOK_COMMA,    value=",", line=char_line, col=char_col); }
        if (char == '[') { lexer_advance(l); return WhitelangTokens.Token(type=TOK_LBRACKET, value="[", line=char_line, col=char_col); }
        if (char == ']') { lexer_advance(l); return WhitelangTokens.Token(type=TOK_RBRACKET, value="]", line=char_line, col=char_col); }
        if (char == ':') { lexer_advance(l); return WhitelangTokens.Token(type=TOK_COLON, value=":", line=char_line, col=char_col); }
        if (char == '?') { lexer_advance(l); return WhitelangTokens.Token(type=TOK_QUESTION, value="?", line=char_line, col=char_col); }

        throw_illegal_char(l.pos, "unknown character '" + char + "'. ");
        lexer_advance(l);
        continue;
    }

    return WhitelangTokens.Token(type=TOK_EOF, value="", line=l.pos.ln, col=l.pos.col);
}
