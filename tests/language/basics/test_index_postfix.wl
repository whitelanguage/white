// Test: INDEX_POSTFIX
// File: tests/language/basics/test_index_postfix.wl
// Focus: Indexed postfix updates return the old value and evaluate the index once.
let CALLS: Int = 0;

func index() -> Int {
    CALLS++;
    return 0;
}

func main() -> Int {
    let values: Vector(Int) = [10];
    let before = values[index()]++;
    let after = values[index()]--;
    let floats: Vector(Float) = [1.5];
    let old = floats[0]++;
    if (before != 10 || after != 11 || values[0] != 10 || CALLS != 2 || old != 1.5 || floats[0] != 2.5) {
        print("FAIL: indexed postfix update");
        return 1;
    }
    print("PASS: indexed postfix update");
    return 0;
}
