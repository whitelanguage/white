// Test: OPTIONAL_FLOW
// File: tests/language/types/test_optional_flow.wl
// Focus: Guarded reads retain union storage through branches and assignment.

func length(value: Optional(String)) -> Int {
    if (value is null) {
        return 0;
    }
    return value.length();
}

func present(value: Optional(String)) -> Bool {
    return value is !null && value.length() > 0;
}

func missing(value: Optional(String)) -> Bool {
    return value is null || value.length() == 0;
}

func unchanged() -> Void {}

struct Pair(left: Int, right: Int)

class Holder {
    let text: Optional(String);
    init() { self.text = "field"; }
    func length() -> Int {
        if (self.text is null) { return 0; }
        return self.text.length();
    }
}

func echo(value: Int) -> Int { return value; }

func main() -> Int {
    let value: Optional(String) = "hello";
    if (value is !null) {
        unchanged();
        let text: String = value;
        if (text != "hello") { return 1; }
    } else {
        return 2;
    }
    if (length(value) != 5 || !present(value) || missing(value)) { return 3; }
    value = null;
    if (length(value) != 0 || present(value) || !missing(value)) { return 4; }

    let count: Optional(Int) = 42;
    if (count is null) { return 5; }
    let inferred = count + 1;
    let inferred_member = count;
    if (inferred_member != 42) { return 17; }
    if (inferred != 43) { return 6; }
    count = null;
    if (count is !null) { return 7; }

    let pair: Optional(Pair) = Pair(1, 2);
    if (pair is null) { return 8; }
    pair.left = 10;
    if (pair.left != 10 || pair.right != 2) { return 9; }
    let holder: Optional(Holder) = Holder();
    if (holder is null) { return 10; }
    if (holder.length() != 5) { return 11; }
    let function: Optional(Function(Int) -> Int) = echo;
    if (function is null) { return 12; }
    if (function(42) != 42) { return 13; }
    let numbers: Optional(Vector(Int)) = [7, 8];
    if (numbers is null) { return 14; }
    numbers.append(9);
    if (numbers.length() != 3 || numbers[2] != 9) { return 15; }
    let loop: Optional(Int) = 2;
    let sum = 0;
    while (loop is !null) {
        sum += loop;
        loop = null;
    }
    if (sum != 2) { return 16; }
    print("PASS: optional flow");
    return 0;
}
