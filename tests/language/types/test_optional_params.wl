// Test: OPTIONAL_PARAMS
// File: tests/language/types/test_optional_params.wl
// Focus: Parameters after a value record containing Optional keep their values and ownership.

struct TextPart(text: Optional(String))


func measure(part: TextPart, count: Int, suffix: String) -> Int {
    let text = part.text;
    if (text is null) { return count + suffix.length(); }
    return text.length() + count + suffix.length();
}

func main() -> Int {
    if (measure(TextPart(null), 7, "xy") != 9) { return 1; }
    if (measure(TextPart(""), 11, "abc") != 14) { return 2; }
    if (measure(TextPart("hello"), 3, "!") != 9) { return 3; }
    print("PASS: Optional parameters");
    return 0;
}
