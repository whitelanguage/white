// Test: STRING_TEMPORARIES
// File: tests/language/memory/test_string_temps.wl
// Focus: Releasing temporary strings created by formatting, concatenation, comparison, and slicing.


func main() -> Int {
    let i: Int = 0;
    while (i < 100000) {
        let text: String = "value-" + i;
        let copy: String = text[:];
        if (copy != "value-" + i || text[0:5] != "value") {
            print("FAIL: String temporary ownership");
            return 1;
        }
        i += 1;
    }
    print("PASS: String temporary ownership");
    return 0;
}
