// Test: CLASS_TYPE_CONVERSION
// File: tests/language/oop/test_class_conversion.wl
// Focus: Explicit class conversions, fallible conversion handling, and inherited dispatch.

import Error from "errors"

class NumberText {
    let text: String = "";
    let value: Int = 0;

    init(text: String, value: Int) -> Void {
        self.text = text;
        self.value = value;
    }

    type String {
        return self.text;
    }

    type Int? {
        if (self.value < 0) {
            throw Error.InvalidArgument;
        }
        return self.value;
    }
}

class TaggedNumber(NumberText) {
    type String {
        return "tag:" + self.text;
    }
}

func read_fallible(value: NumberText) -> Int {
    let result: Int = Int(value)?;
    catch(err) {
        if (err == Error.InvalidArgument) { return -1; }
        return -2;
    }
    return result;
}

func main() -> Int {
    let number: NumberText = NumberText("seven", 7);
    let invalid: NumberText = NumberText("invalid", -1);
    let tagged: TaggedNumber = TaggedNumber();
    tagged.text = "nine";
    tagged.value = 9;

    if (String(number) != "seven") { return 1; }
    if (Int(number) != 7) { return 2; }
    if (read_fallible(number) != 7) { return 3; }
    if (read_fallible(invalid) != -1) { return 4; }
    if (String(tagged) != "tag:nine") { return 5; }
    if (Int(tagged) != 9) { return 6; }

    print("PASS: class type conversions");
    return 0;
}
