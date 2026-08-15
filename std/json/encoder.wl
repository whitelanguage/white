// std/json/encoder.wl

import Builder from "strings"
import JsonError from "errors.wl"
import Kind from "value.wl"
import Value from "value.wl"
import validate_number from "value.wl"

const __MAX_DEPTH: Int = 1024;

class Encoder {
    let __indent: Int = 0;
    let __max_depth: Int = 512;

    init() {
        self.__indent = 0;
        self.__max_depth = 512;
    }

    func set_indent(indent: Int) -> Void {
        self.__indent = indent;
    }

    func set_max_depth(max_depth: Int) -> Void {
        self.__max_depth = max_depth;
    }

    func __write_indent(output: Builder, depth: Int) -> Void? {
        output.write_byte(Byte(10))?;
        let count: Int = depth * self.__indent;
        let i: Int = 0;
        while (i < count) {
            output.write_byte(Byte(32))?;
            i += 1;
        }
        return;
    }

    func __hex(value: Int) -> Byte {
        if (value < 10) { return Byte(value + 48); }
        return Byte(value - 10 + 97);
    }

    func __write_string(output: Builder, value: String) -> Void? {
        if (value is null || !value.is_valid_utf8()) {
            throw JsonError.InvalidUtf8;
        }
        output.write_byte(Byte(34))?;
        let i: Int = 0;
        while (i < value.length()) {
            let byte: Int = Int(value[i]);
            if (byte == 34) {
                output.write("\\\"")?;
            } else if (byte == 92) {
                output.write("\\\\")?;
            } else if (byte == 8) {
                output.write("\\b")?;
            } else if (byte == 12) {
                output.write("\\f")?;
            } else if (byte == 10) {
                output.write("\\n")?;
            } else if (byte == 13) {
                output.write("\\r")?;
            } else if (byte == 9) {
                output.write("\\t")?;
            } else if (byte < 32) {
                output.write("\\u00")?;
                output.write_byte(self.__hex((byte >> 4) & 15))?;
                output.write_byte(self.__hex(byte & 15))?;
            } else {
                output.write_byte(Byte(byte))?;
            }
            i += 1;
        }
        output.write_byte(Byte(34))?;
        return;
    }

    func __write_array(output: Builder, value: Value, depth: Int) -> Void? {
        let length: Int = value.length()?;
        output.write_byte(Byte(91))?;
        let i: Int = 0;
        while (i < length) {
            if (i > 0) { output.write_byte(Byte(44))?; }
            if (self.__indent > 0) { self.__write_indent(output, depth + 1)?; }
            self.__write_value(output, value.at(i)?, depth + 1)?;
            i += 1;
        }
        if (length > 0 && self.__indent > 0) {
            self.__write_indent(output, depth)?;
        }
        output.write_byte(Byte(93))?;
        return;
    }

    func __write_object(output: Builder, value: Value, depth: Int) -> Void? {
    // object keys keep insertion order, so output is stable across runs
        let length: Int = value.length()?;
        output.write_byte(Byte(123))?;
        let i: Int = 0;
        while (i < length) {
            if (i > 0) { output.write_byte(Byte(44))?; }
            if (self.__indent > 0) { self.__write_indent(output, depth + 1)?; }
            let key: String = value.key_at(i)?;
            self.__write_string(output, key)?;
            output.write_byte(Byte(58))?;
            if (self.__indent > 0) { output.write_byte(Byte(32))?; }
            self.__write_value(output, value.get(key)?, depth + 1)?;
            i += 1;
        }
        if (length > 0 && self.__indent > 0) {
            self.__write_indent(output, depth)?;
        }
        output.write_byte(Byte(125))?;
        return;
    }

    func __write_value(output: Builder, value: Value, depth: Int) -> Void? {
        if (value is null) { throw JsonError.InvalidValue; }
        let kind: Kind = value.kind();
        if (kind == Kind.Null) {
            output.write("null")?;
            return;
        }
        if (kind == Kind.Boolean) {
            if (value.as_bool()?) { output.write("true")?; }
            else { output.write("false")?; }
            return;
        }
        if (kind == Kind.Number) {
            let source: String = value.as_number_text()?;
            validate_number(source)?;
            output.write(source)?;
            return;
        }
        if (kind == Kind.Text) {
            self.__write_string(output, value.as_string()?)?;
            return;
        }
        if (depth >= self.__max_depth) {
            throw JsonError.NestingTooDeep;
        }
        if (kind == Kind.Array) {
            self.__write_array(output, value, depth)?;
            return;
        }
        if (kind == Kind.Object) {
            self.__write_object(output, value, depth)?;
            return;
        }
        throw JsonError.InvalidValue;
    }

    func encode(value: Value) -> String? {
        if (self.__indent < 0 || self.__indent > 16) {
            throw JsonError.InvalidIndent;
        }
        if (self.__max_depth < 1 || self.__max_depth > __MAX_DEPTH) {
            throw JsonError.InvalidOption;
        }
        let output: Builder = Builder(256);
        self.__write_value(output, value, 0)?;
        return output.build()?;
    }
}

func encode(value: Value) -> String? {
    let encoder: Encoder = Encoder();
    return encoder.encode(value)?;
}
