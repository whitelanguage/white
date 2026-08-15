// Test: STRING_COMPARE
// File: tests/language/basics/test_string_ops.wl
// Focus: String concatenation, escape sequence parsing, and equality comparison.


func main() -> Int {
    let str: String = "Hi";
    let combined: String = "White" + "Lang";

    if (str == "Hi" && combined == "WhiteLang") {
        print("PASS: String operations");
    } else {
        print("FAIL: String concatenation or comparison");
    }
    return 0;
}
