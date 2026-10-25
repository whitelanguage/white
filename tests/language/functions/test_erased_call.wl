// Test: ERASED_CALL
// File: tests/language/functions/test_erased_call.wl
// Focus: Preserving a known callable signature through Function and Method bindings.

func increment(value: Int) -> Int {
    return value + 1;
}

class Counter {
    func increment(value: Int) -> Int {
        return value + 2;
    }
}

func main() -> Int {
    let f: Function = increment;
    let counter = Counter();
    let m: Method = counter.increment;
    if (f(10) != 11 || m(10) != 12) {
        print("FAIL: erased callable signature");
        return 1;
    }

    print("PASS: erased callable signature");
    return 0;
}
