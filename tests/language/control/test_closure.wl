// Test: CLOSURE_STATE_CAPTURE
// File: tests/language/control/test_closure.wl
// Focus: Lexical scoping, variable capturing in nested functions, and persistent state across calls.


func main() -> Int {
    func outer() -> Function() -> Int {
        let age: Int = 1;
        func inner() -> Int {
            let increment: Int = 5;
            age = age + increment;
            return age;
        }
        return inner;
    }
    
    let counter_fn: Function() -> Int = outer();
    let first_call: Int = counter_fn();  // 1 + 5 = 6
    let second_call: Int = counter_fn(); // 6 + 5 = 11
    
    if (first_call == 6 && second_call == 11) {
        print("PASS: Closure variable capture and persistence");
    } else {
        print("FAIL: Closure state, got " + second_call);
        return 1;
    }
    return 0;
}
