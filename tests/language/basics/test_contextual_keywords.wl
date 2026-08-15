// Test: CONTEXTUAL_KEYWORDS
// File: tests/language/basics/test_contextual_keywords.wl
// Focus: Using type as an identifier outside a conversion declaration.

class Names {
    let type: Int = 2;

    init() -> Void {
        self.type = 2;
    }
}

func add_one(type: Int) -> Int {
    let result: Int = type + 1;
    return result;
}

func main() -> Int {
    let value: Names = Names();
    if (value.type != 2 || add_one(4) != 5) {
        print("FAIL: Contextual keyword handling");
        return 1;
    }
    print("PASS: Contextual keyword handling");
    return 0;
}
