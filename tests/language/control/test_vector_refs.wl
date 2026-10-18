// Test: VECTOR_REFERENCES
// File: tests/language/control/test_vector_refs.wl
// Focus: Scoped element references allow writes and release their storage restriction at block exit.

func add_first<T>(values: Vector(T), amount: T) -> T {
    let first: T = ref values[0];
    let separate: Vector(Int) = [5];
    separate.append(6);
    first = first + amount;
    return first;
}

class Counter {
    func increment(values: Vector(Int)) -> Void {
        let first = ref values[0];
        first++;
    }
}

func count(values: Vector(Int)) -> Int {
    return values.length();
}

func main() -> Int {
    let values: Vector(Int) = [1, 2];
    let other: Vector(Int) = [3, 4];
    if true {
        let first = ref values[0];
        other.append(5);
        let copy = other;
        copy.append(6);
        other = [7, 8];
        other.drop();
        let fresh: Vector(Int) = [];
        fresh.append(9);
        if true {
            let values: Vector(Int) = [20];
            values.append(21);
        }
        if (other.length() != 1 || other[0] != 7 || copy.length() != 4 || fresh[0] != 9) {
            print("FAIL: Independent Vector storage");
            return 1;
        }
        let same: Int = ref values[0];
        first = 10;
        same++;
        values[1] = first + 1;
        const read_only = ref values[0];
        if (read_only != 11 || values.length() != 2) {
            print("FAIL: Element reference writes");
            return 1;
        }
    }
    if (count(values) != 2 || count(other) != 1) {
        print("FAIL: Separate published owners");
        return 1;
    }
    values.append(3);
    if (values[0] != 11 || values[1] != 12 || values[2] != 3) {
        print("FAIL: Element reference scope");
        return 1;
    }

    let i = 0;
    while (i < 4) {
        if true {
            let first = ref values[0];
            first++;
        }
        values.append(i);
        i++;
    }
    if (values[0] != 15 || values.length() != 7) {
        print("FAIL: Element reference loop");
        return 1;
    }

    let words: Vector(String) = ["old"];
    if true {
        let word = ref words[0];
        word = "new";
        if (word != "new" || word.length() != 3) {
            print("FAIL: String element reference");
            return 1;
        }
    }

    let counter = Counter();
    counter.increment(values);
    if (add_first(values, 2) != 18) {
        print("FAIL: Generic and method element references");
        return 1;
    }

    for (let step = 0; step < 3; step++) {
        let first = ref values[0];
        if (step == 0) {
            first++;
            continue;
        }
        first++;
        break;
    }
    values.append(4);
    if (values[0] != 20 || values.length() != 8) {
        print("FAIL: Element reference control flow");
        return 1;
    }

    print("PASS: Scoped Vector references");
    return 0;
}
