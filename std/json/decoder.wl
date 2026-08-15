// std/json/decoder.wl

import Error from "errors"
import Builder from "strings"
import JsonError from "errors.wl"
import Value from "value.wl"
import null_value from "value.wl"
import boolean from "value.wl"
import number_from_text from "value.wl"
import string from "value.wl"
import array from "value.wl"
import object from "value.wl"

const __MAX_DEPTH: Int = 1024;

class Decoder {
    let __source: String = null;
    let __index: Int = 0;
    let __line: Int = 1;
    let __column: Int = 1;
    let __max_depth: Int = 512;
    let __error_offset: Int = -1;
    let __error_line: Int = 0;
    let __error_column: Int = 0;

    init(source: String) {
        self.__source = source;
        self.__max_depth = 512;
    }

    func set_max_depth(max_depth: Int) -> Void {
        self.__max_depth = max_depth;
    }

    func offset() -> Int {
        return self.__error_offset;
    }

    func line() -> Int {
        return self.__error_line;
    }

    func column() -> Int {
        return self.__error_column;
    }

    func __fail(reason: JsonError) -> Void? {
        self.__error_offset = self.__index;
        self.__error_line = self.__line;
        self.__error_column = self.__column;
        throw reason;
    }

    func __peek() -> Int {
        if (self.__source is null || self.__index >= self.__source.length()) {
            return -1;
        }
        return Int(self.__source[self.__index]);
    }

    func __take() -> Int {
        let value: Int = self.__peek();
        if (value < 0) { return -1; }
        self.__index += 1;
        if (value == 10) {
            self.__line += 1;
            self.__column = 1;
        } else {
            self.__column += 1;
        }
        return value;
    }

    func __skip_space() -> Void {
        while true {
            let value: Int = self.__peek();
            if (value != 32 && value != 9 && value != 10 && value != 13) {
                return;
            }
            self.__take();
        }
    }

    func __literal(expected: String) -> Void? {
        let i: Int = 0;
        while (i < expected.length()) {
            if (self.__peek() < 0) {
                self.__fail(JsonError.UnexpectedEnd)?;
            }
            if (self.__take() != Int(expected[i])) {
                self.__fail(JsonError.UnexpectedToken)?;
            }
            i += 1;
        }
        return;
    }

    func __hex_digit(value: Int) -> Int {
        if (value >= 48 && value <= 57) { return value - 48; }
        if (value >= 65 && value <= 70) { return value - 55; }
        if (value >= 97 && value <= 102) { return value - 87; }
        return -1;
    }

    func __unicode_escape() -> Char? {
    // json spells non-BMP scalars as a UTF-16 surrogate pair
        let scalar: Int = 0;
        let i: Int = 0;
        while (i < 4) {
            let raw: Int = self.__take();
            let digit: Int = self.__hex_digit(raw);
            if (raw < 0) { self.__fail(JsonError.UnexpectedEnd)?; }
            if (digit < 0) { self.__fail(JsonError.InvalidUnicodeEscape)?; }
            scalar = (scalar << 4) | digit;
            i += 1;
        }

        if (scalar >= 55296 && scalar <= 56319) {
            if (self.__take() != 92 || self.__take() != 117) {
                self.__fail(JsonError.InvalidUnicodeEscape)?;
            }
            let low: Int = 0;
            i = 0;
            while (i < 4) {
                let raw: Int = self.__take();
                let digit: Int = self.__hex_digit(raw);
                if (raw < 0) { self.__fail(JsonError.UnexpectedEnd)?; }
                if (digit < 0) { self.__fail(JsonError.InvalidUnicodeEscape)?; }
                low = (low << 4) | digit;
                i += 1;
            }
            if (low < 56320 || low > 57343) {
                self.__fail(JsonError.InvalidUnicodeEscape)?;
            }
            scalar = 65536 + ((scalar - 55296) << 10) + (low - 56320);
        } else if (scalar >= 56320 && scalar <= 57343) {
            self.__fail(JsonError.InvalidUnicodeEscape)?;
        }
        return Char(scalar);
    }

    func __string() -> String? {
        if (self.__take() != 34) { self.__fail(JsonError.UnexpectedToken)?; }
        let output: Builder = Builder(64);

        while true {
            let value: Int = self.__take();
            if (value < 0) { self.__fail(JsonError.UnexpectedEnd)?; }
            if (value == 34) { return output.build()?; }
            if (value < 32) { self.__fail(JsonError.InvalidControlCharacter)?; }

            if (value != 92) {
                output.write_byte(Byte(value))?;
                continue;
            }

            let escaped: Int = self.__take();
            if (escaped < 0) { self.__fail(JsonError.UnexpectedEnd)?; }
            if (escaped == 34 || escaped == 92 || escaped == 47) {
                output.write_byte(Byte(escaped))?;
            } else if (escaped == 98) {
                output.write_byte(Byte(8))?;
            } else if (escaped == 102) {
                output.write_byte(Byte(12))?;
            } else if (escaped == 110) {
                output.write_byte(Byte(10))?;
            } else if (escaped == 114) {
                output.write_byte(Byte(13))?;
            } else if (escaped == 116) {
                output.write_byte(Byte(9))?;
            } else if (escaped == 117) {
                output.write_char(self.__unicode_escape()?)?;
            } else {
                self.__fail(JsonError.InvalidEscape)?;
            }
        }
        return "";
    }

    func __number() -> Value? {
        let start: Int = self.__index;
        if (self.__peek() == 45) { self.__take(); }
        if (self.__peek() < 0) { self.__fail(JsonError.UnexpectedEnd)?; }

        if (self.__peek() == 48) {
            self.__take();
            let next: Int = self.__peek();
            if (next >= 48 && next <= 57) {
                self.__fail(JsonError.InvalidNumber)?;
            }
        } else {
            if (self.__peek() < 49 || self.__peek() > 57) {
                self.__fail(JsonError.InvalidNumber)?;
            }
            while (self.__peek() >= 48 && self.__peek() <= 57) {
                self.__take();
            }
        }

        if (self.__peek() == 46) {
            self.__take();
            if (self.__peek() < 48 || self.__peek() > 57) {
                self.__fail(JsonError.InvalidNumber)?;
            }
            while (self.__peek() >= 48 && self.__peek() <= 57) {
                self.__take();
            }
        }

        if (self.__peek() == 101 || self.__peek() == 69) {
            self.__take();
            if (self.__peek() == 43 || self.__peek() == 45) {
                self.__take();
            }
            if (self.__peek() < 48 || self.__peek() > 57) {
                self.__fail(JsonError.InvalidNumber)?;
            }
            while (self.__peek() >= 48 && self.__peek() <= 57) {
                self.__take();
            }
        }

        let source: String = self.__source[start:self.__index];
        if (source is null) { throw Error.OutOfMemory; }
        return number_from_text(source)?;
    }

    func __array(depth: Int) -> Value? {
        self.__take();
        let result: Value = array();
        self.__skip_space();
        if (self.__peek() == 93) {
            self.__take();
            return result;
        }

        while true {
            let item: Value = self.__value(depth)?;
            result.append(item)?;
            self.__skip_space();
            let delimiter: Int = self.__take();
            if (delimiter == 93) { return result; }
            if (delimiter != 44) { self.__fail(JsonError.UnexpectedToken)?; }
            self.__skip_space();
        }
        return null_value();
    }

    func __object(depth: Int) -> Value? {
        self.__take();
        let result: Value = object();
        self.__skip_space();
        if (self.__peek() == 125) {
            self.__take();
            return result;
        }

        while true {
            if (self.__peek() != 34) {
                self.__fail(JsonError.UnexpectedToken)?;
            }
            let key: String = self.__string()?;
            self.__skip_space();
            if (self.__take() != 58) {
                self.__fail(JsonError.UnexpectedToken)?;
            }
            self.__skip_space();
            let item: Value = self.__value(depth)?;
            result.set(key, item)?;
            self.__skip_space();
            let delimiter: Int = self.__take();
            if (delimiter == 125) { return result; }
            if (delimiter != 44) { self.__fail(JsonError.UnexpectedToken)?; }
            self.__skip_space();
        }
        return null_value();
    }

    func __value(depth: Int) -> Value? {
        self.__skip_space();
        let value: Int = self.__peek();
        if (value < 0) { self.__fail(JsonError.UnexpectedEnd)?; }
        if (value == 34) { return string(self.__string()?)?; }
        if (value == 91) {
            if (depth >= self.__max_depth) {
                self.__fail(JsonError.NestingTooDeep)?;
            }
            return self.__array(depth + 1)?;
        }
        if (value == 123) {
            if (depth >= self.__max_depth) {
                self.__fail(JsonError.NestingTooDeep)?;
            }
            return self.__object(depth + 1)?;
        }
        if (value == 116) {
            self.__literal("true")?;
            return boolean(true);
        }
        if (value == 102) {
            self.__literal("false")?;
            return boolean(false);
        }
        if (value == 110) {
            self.__literal("null")?;
            return null_value();
        }
        if (value == 45 || (value >= 48 && value <= 57)) {
            return self.__number()?;
        }
        self.__fail(JsonError.UnexpectedToken)?;
        return null_value();
    }

    func decode() -> Value? {
    // validate the complete input before copying string bytes into values
        self.__index = 0;
        self.__line = 1;
        self.__column = 1;
        self.__error_offset = -1;
        self.__error_line = 0;
        self.__error_column = 0;

        if (self.__source is null) { self.__fail(JsonError.InvalidValue)?; }
        if (self.__max_depth < 1 || self.__max_depth > __MAX_DEPTH) {
            self.__fail(JsonError.InvalidOption)?;
        }
        if (!self.__source.is_valid_utf8()) { self.__fail(JsonError.InvalidUtf8)?; }

        self.__skip_space();
        let result: Value = self.__value(0)?;
        self.__skip_space();
        if (self.__peek() >= 0) { self.__fail(JsonError.TrailingData)?; }
        return result;
    }
}

func decode(source: String) -> Value? {
    let decoder: Decoder = Decoder(source);
    return decoder.decode()?;
}
