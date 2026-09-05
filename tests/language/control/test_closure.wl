// Test: CLOSURE_STATE_CAPTURE
// File: tests/language/control/test_closure.wl
// Focus: Lexical scoping, variable capturing in nested functions, and persistent state across calls.

let CLOSURE_DROPPED: Int = 0;

class ClosureProbe {
    let value: Int;

    init(value: Int) {
        self.value = value;
    }

    deinit() {
        CLOSURE_DROPPED++;
    }
}

func make_reader() -> Function() -> Int {
    let probe = ClosureProbe(17);
    func read() -> Int {
        return probe.value;
    }
    return read;
}

func exercise_reader() -> Bool {
    let reader = make_reader();
    if (CLOSURE_DROPPED != 0) { return false; }
    return reader() == 17;
}

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
        if (!exercise_reader() || CLOSURE_DROPPED != 1) {
            print("FAIL: Closure capture lifetime");
            return 1;
        }
        print("PASS: Closure variable capture and persistence");
    } else {
        print("FAIL: Closure state, got " + second_call);
        return 1;
    }
    return 0;
}
