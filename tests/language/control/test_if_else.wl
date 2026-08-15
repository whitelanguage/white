// Test: IF_ELSE_CONDITIONAL
// File: tests/language/control/test_if_else.wl
// Focus: Boolean condition evaluation, code block scoping, and post-increment side effects.


func main() -> Int {
    let a: Int = 10;

    if (true) {
        a++;
        a++;
    }

    // expected 12
    if (a == 12) {
        print("PASS: Conditional branching and increment");
    } else {
        print("FAIL: Condition logic or increment error. Got: " + a);
    }
    return 0;
}
