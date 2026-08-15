// Test: FOR_LOOP_ITERATION
// File: tests/language/control/test_for_loop.wl
// Focus: Standard C-style for-loop syntax (init; cond; post) and iterator mutation.


func main() -> Int {
    let limit: Int = 5;
    let counter: Int = 0;

    for (i: Int = 0; i < limit; i++) {
        counter = counter + 1;
    }

    if (counter == 5) {
        print("PASS: For loop execution");
    } else {
        print("FAIL: Loop iteration count mismatch");
    }
    return 0;
}
