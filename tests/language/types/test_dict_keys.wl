// Test: DICT_KEYS
// File: tests/language/types/test_dict_keys.wl
// Focus: Dynamic Dict keys preserve their type and use value or identity equality as appropriate.

enum Mode {
    Read,
    Write,
}

class Token {
    let value: Int;

    init(value: Int) {
        self.value = value;
    }
}

func main() -> Int {
    let token: Token = Token(7);
    let equal_text: String = "na" + "me";
    let wide_signed: Int128 = 170141183460469231731687303715884105727LL;
    let wide_unsigned: UInt128 = 340282366920938463463374607431768211455ULL;

    let values: Dict = {
        "name": "white",
        1: "int",
        1L: "long",
        1UL: "uint64",
        true: "bool",
        'W': "char",
        Mode.Read: "enum",
        -0.0: "zero",
        token: "object",
        null: "null",
        wide_signed: "int128",
        wide_unsigned: "uint128",
    };

    let name: String = values[equal_text];
    let int_value: String = values[1];
    let long_value: String = values[1L];
    let uint_value: String = values[1UL];
    let bool_value: String = values[true];
    let char_value: String = values['W'];
    let enum_value: String = values[Mode.Read];
    let zero_value: String = values[0.0];
    let object_value: String = values[token];
    let null_value: String = values[null];
    let int128_value: String = values[wide_signed];
    let uint128_value: String = values[wide_unsigned];

    let passed: Bool = values.length() == 12 && name == "white" && int_value == "int" && long_value == "long" && uint_value == "uint64" && bool_value == "bool" && char_value == "char" && enum_value == "enum" && zero_value == "zero" && object_value == "object" && null_value == "null" && int128_value == "int128" && uint128_value == "uint128";
    values.remove(1L);
    passed = passed && !values.contains_key(1L) && values.contains_key(1) && values.length() == 11;
    values.clear();
    passed = passed && values.is_empty();

    if passed {
        print("PASS: Dynamic Dict keys");
        return 0;
    }
    print("FAIL: Dynamic Dict keys");
    return 1;
}
