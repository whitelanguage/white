// Test: METHOD_NAMES
// File: tests/language/classes/test_method_names.wl
// Focus: Container intrinsic names do not override class method return inference.

class Measure {
    func length() -> String { return "units"; }
    func append() -> String { return "append"; }
    func drop() -> String { return "drop"; }
}

func main() -> Int {
    let value = Measure();
    let length = value.length();
    let appended = value.append();
    let dropped = value.drop();
    if (length != "units" || appended != "append" || dropped != "drop") {
        print("FAIL: class method return inference");
        return 1;
    }

    print("PASS: class method names");
    return 0;
}
