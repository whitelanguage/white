// Test: OPTIONAL_GLOBAL
// File: tests/language/types/test_optional_global.wl
// Focus: Static union tags, inline payloads, relocations and writable globals.

struct Pair(left: String, right: String)
struct Record(value: Optional(Int), text: Optional(String))

let absent: Optional(Int) = null;
let count: Optional(Int) = 42;
let text: Optional(String) = "hello";
const wide: Int128 | String | Null = "wide";
const float_value: Optional(Float) = 1.5;
const bool_value: Optional(Bool) = true;
const int_value: Optional(Int128) = 123456789012345678901234567890LL;
let pair: Optional(Pair) = Pair("left", "right");
const aligned: Int128 | Pair | Null = Pair("a", "b");
let nested: Optional(Record) = Record(7, "nested");

func check() -> Int {
    if (count is null) { return 1; }
    if (count != 42) { return 2; }
    if (text is null) { return 3; }
    if (text != "hello") { return 4; }
    if (float_value is null || float_value != 1.5) { return 5; }
    if (bool_value is null || !bool_value) { return 6; }
    if (int_value is null || int_value != 123456789012345678901234567890LL) { return 7; }
    if (pair is null) { return 8; }
    if (pair.left != "left" || pair.right != "right") { return 9; }
    if (nested is null) { return 10; }
    if (nested.value is null || nested.value != 7) { return 11; }
    if (nested.text is null || nested.text != "nested") { return 12; }
    return 0;
}

func main() -> Int {
    if (check() != 0) { return 1; }
    if (absent is !null || wide is null || aligned is null) { return 2; }
    text = "changed";
    if (text is null) { return 3; }
    if (text != "changed") { return 4; }
    text = null;
    if (text is !null) { return 5; }
    count = null;
    if (count is !null) { return 6; }
    print("PASS: optional globals");
    return 0;
}
