// std/json/value.wl

import Dict from "dict"
import Error from "errors"
import JsonError from "errors.wl"

enum Kind {
    Null,
    Boolean,
    Number,
    Text,
    Array,
    Object
}

class Object {
    let __values: Dict = null;
    let __keys: Vector(String) = null;

    init() {
        self.__values = Dict(8);
        self.__keys = [];
    }

    func length() -> Int {
        return self.__keys.length();
    }

    func contains(key: String) -> Bool {
        if (key is null) { return false; }
        return self.__values.contains_key(key);
    }

    func find(key: String) -> Value {
        if (!self.contains(key)) { return null; }
        let value: Value = self.__values.get(key);
        return value;
    }

    func get(key: String) -> Value? {
        let value: Value = self.find(key);
        if (value is null) { throw JsonError.MissingKey; }
        return value;
    }

    func set(key: String, value: Value) -> Void? {
    // copy new keys because Dict hashes the stored bytes
        if (key is null || value is null) { throw JsonError.InvalidValue; }
        if (!self.__values.contains_key(key)) {
            let stored_key: String = key[:];
            if (stored_key is null) { throw Error.OutOfMemory; }
            self.__keys.append(stored_key);
            self.__values.put(stored_key, value);
            return;
        }
        self.__values.put(key, value);
        return;
    }

    func remove(key: String) -> Bool {
        if (!self.contains(key)) { return false; }
        self.__values.remove(key);

        let i: Int = 0;
        while (i < self.__keys.length()) {
            if (self.__keys[i] == key) {
                let j: Int = i;
                while (j + 1 < self.__keys.length()) {
                    self.__keys[j] = self.__keys[j + 1];
                    j += 1;
                }
                self.__keys.drop();
                return true;
            }
            i += 1;
        }
        return true;
    }

    func key_at(index: Int) -> String? {
        if (index < 0 || index >= self.__keys.length()) {
            throw JsonError.IndexOutOfBounds;
        }
        return self.__keys[index];
    }

    func value_at(index: Int) -> Value? {
        let key: String = self.key_at(index)?;
        return self.get(key)?;
    }
}

class Value {
    let __kind: Kind = Kind.Null;
    let __boolean: Bool = false;
    let __number: Float = 0.0;
    let __number_text: String = null;
    let __text: String = null;
    let __array: Vector(Value) = null;
    let __object: Object = null;

    init(kind: Kind) {
        self.__kind = kind;
        if (kind == Kind.Array) { self.__array = []; }
        if (kind == Kind.Object) { self.__object = Object(); }
    }

    func kind() -> Kind {
        return self.__kind;
    }

    func is_null() -> Bool {
        return self.__kind == Kind.Null;
    }

    func as_bool() -> Bool? {
        if (self.__kind != Kind.Boolean) { throw JsonError.TypeMismatch; }
        return self.__boolean;
    }

    func as_float() -> Float? {
        if (self.__kind != Kind.Number) { throw JsonError.TypeMismatch; }
        return self.__number;
    }

    func as_number_text() -> String? {
        if (self.__kind != Kind.Number) { throw JsonError.TypeMismatch; }
        return self.__number_text;
    }

    func as_long() -> Long? {
        if (self.__kind != Kind.Number) { throw JsonError.TypeMismatch; }
        let source: String = self.__number_text;
        if (source is null || source.length() == 0) { throw JsonError.InvalidNumber; }

        let negative: Bool = source[0] == '-';
        let i: Int = 0;
        if (negative) { i = 1; }
        if (i >= source.length()) { throw JsonError.InvalidNumber; }

        let value: Long = 0L;
        let min_value: Long = -9223372036854775807L - 1L;
        while (i < source.length()) {
            let byte: Int = Int(source[i]);
            if (byte < 48 || byte > 57) { throw JsonError.NumberNotInteger; }
            let digit: Long = Long(byte - 48);
            if (value < (min_value + digit) / 10L) {
                throw JsonError.NumberOutOfRange;
            }
            value = value * 10L - digit;
            i += 1;
        }

        if negative { return value; }
        if (value == min_value) { throw JsonError.NumberOutOfRange; }
        return 0L - value;
    }

    func as_string() -> String? {
        if (self.__kind != Kind.Text) { throw JsonError.TypeMismatch; }
        return self.__text;
    }

    type Bool? {
        return self.as_bool()?;
    }

    type Float? {
        return self.as_float()?;
    }

    type Long? {
        return self.as_long()?;
    }

    type String? {
        return self.as_string()?;
    }

    func as_object() -> Object? {
        if (self.__kind != Kind.Object) { throw JsonError.TypeMismatch; }
        return self.__object;
    }

    func length() -> Int? {
        if (self.__kind == Kind.Array) { return self.__array.length(); }
        if (self.__kind == Kind.Object) { return self.__object.length(); }
        throw JsonError.TypeMismatch;
        return 0;
    }

    func at(index: Int) -> Value? {
        if (self.__kind != Kind.Array) { throw JsonError.TypeMismatch; }
        if (index < 0 || index >= self.__array.length()) {
            throw JsonError.IndexOutOfBounds;
        }
        return self.__array[index];
    }

    func append(value: Value) -> Void? {
        if (self.__kind != Kind.Array) { throw JsonError.TypeMismatch; }
        if (value is null) { throw JsonError.InvalidValue; }
        self.__array.append(value);
        return;
    }

    func get(key: String) -> Value? {
        if (self.__kind != Kind.Object) { throw JsonError.TypeMismatch; }
        return self.__object.get(key)?;
    }

    func find(key: String) -> Value {
        if (self.__kind != Kind.Object) { return null; }
        return self.__object.find(key);
    }

    func contains(key: String) -> Bool {
        if (self.__kind != Kind.Object) { return false; }
        return self.__object.contains(key);
    }

    func set(key: String, value: Value) -> Void? {
        if (self.__kind != Kind.Object) { throw JsonError.TypeMismatch; }
        self.__object.set(key, value)?;
        return;
    }

    func remove(key: String) -> Bool? {
        if (self.__kind != Kind.Object) { throw JsonError.TypeMismatch; }
        return self.__object.remove(key);
    }

    func key_at(index: Int) -> String? {
        if (self.__kind != Kind.Object) { throw JsonError.TypeMismatch; }
        return self.__object.key_at(index)?;
    }
}

func __is_digit(value: Int) -> Bool {
    return value >= 48 && value <= 57;
}

func __parse_number(source: String) -> Float? {
    if (source is null || source.length() == 0) { throw JsonError.InvalidNumber; }
    let i: Int = 0;
    let negative: Bool = false;
    if (source[i] == '-') {
        negative = true;
        i += 1;
        if (i >= source.length()) { throw JsonError.InvalidNumber; }
    }

    let value: Float = 0.0;
    let first: Int = Int(source[i]);
    if (first == 48) {
        i += 1;
        if (i < source.length() && __is_digit(Int(source[i]))) {
            throw JsonError.InvalidNumber;
        }
    } else {
        if (first < 49 || first > 57) { throw JsonError.InvalidNumber; }
        while (i < source.length() && __is_digit(Int(source[i]))) {
            value = value * 10.0 + Float(Int(source[i]) - 48);
            i += 1;
        }
    }

    if (i < source.length() && source[i] == '.') {
        i += 1;
        if (i >= source.length() || !__is_digit(Int(source[i]))) {
            throw JsonError.InvalidNumber;
        }
        let place: Float = 0.1;
        while (i < source.length() && __is_digit(Int(source[i]))) {
            value += Float(Int(source[i]) - 48) * place;
            place *= 0.1;
            i += 1;
        }
    }

    let exponent: Int = 0;
    let exponent_negative: Bool = false;
    if (i < source.length() && (source[i] == 'e' || source[i] == 'E')) {
        i += 1;
        if (i < source.length() && (source[i] == '+' || source[i] == '-')) {
            exponent_negative = source[i] == '-';
            i += 1;
        }
        if (i >= source.length() || !__is_digit(Int(source[i]))) {
            throw JsonError.InvalidNumber;
        }
        while (i < source.length() && __is_digit(Int(source[i]))) {
            if (exponent < 1000000) {
                exponent = exponent * 10 + Int(source[i]) - 48;
            }
            i += 1;
        }
    }

    if (i != source.length()) { throw JsonError.InvalidNumber; }

    let power: Float = 1.0;
    let factor: Float = 10.0;
    let remaining: Int = exponent;
    while (remaining > 0) {
        if ((remaining & 1) == 1) { power *= factor; }
        factor *= factor;
        remaining >>= 1;
    }
    if exponent_negative { value /= power; }
    else { value *= power; }
    if negative { value = -value; }
    return value;
}

func null_value() -> Value {
    return Value(Kind.Null);
}

func boolean(value: Bool) -> Value {
    let result: Value = Value(Kind.Boolean);
    result.__boolean = value;
    return result;
}

func number_from_text(source: String) -> Value? {
// keep the token text so large integers survive a parse/encode round trip
    let approximation: Float = __parse_number(source)?;
    let copy: String = source[:];
    if (copy is null) { throw Error.OutOfMemory; }
    let result: Value = Value(Kind.Number);
    result.__number = approximation;
    result.__number_text = copy;
    return result;
}

func validate_number(source: String) -> Void? {
    __parse_number(source)?;
    return;
}

func number(value: Float) -> Value? {
    let source: String = "" + value;
    if (source is null) { throw Error.OutOfMemory; }
    return number_from_text(source)?;
}

func integer(value: Long) -> Value? {
    let source: String = "" + value;
    if (source is null) { throw Error.OutOfMemory; }
    return number_from_text(source)?;
}

func string(value: String) -> Value? {
    if (value is null || !value.is_valid_utf8()) { throw JsonError.InvalidUtf8; }
    let copy: String = value[:];
    if (copy is null) { throw Error.OutOfMemory; }
    let result: Value = Value(Kind.Text);
    result.__text = copy;
    return result;
}

func array() -> Value {
    return Value(Kind.Array);
}

func object() -> Value {
    return Value(Kind.Object);
}
