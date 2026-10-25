// Test: VECTOR_EVALUATION
// File: tests/language/collections/test_vector_eval.wl
// Focus: Inferring literal types without repeating element side effects.

let calls: Int = 0;
let dropped: Int = 0;

class Probe {
    deinit() {
        dropped++;
    }
}

func next() -> Int {
    calls++;
    return calls;
}

func main() -> Int {
    print([next(), next()]);
    if (calls != 2) {
        print("FAIL: Vector elements evaluated more than once");
        return 1;
    }

    let text: String = "White";
    print([text, "Language"]);
    print([[next()], [next()]]);
    print([]);
    if (calls != 4) {
        print("FAIL: nested Vector evaluation");
        return 1;
    }

    print([Probe()]);
    print([[Probe()]]);
    if (dropped != 2) {
        print("FAIL: temporary Vector elements were not released");
        return 1;
    }

    print("PASS: Vector literal evaluation");
    return 0;
}
