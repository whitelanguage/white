// Test: OWNERSHIP_CONTRACT
// File: tests/language/memory/test_ownership.wl
// Focus: Owned returns, parameter lifetimes, partial arrays, and Vector.drop ownership transfer.


let DROPPED: Int = 0;

class Probe {
    let value: Int = 0;

    init(value: Int) -> Void {
        self.value = value;
    }

    deinit() -> Void {
        DROPPED += 1;
    }
}

func make_probe(value: Int) -> Probe {
    return Probe(value);
}

func read_probe(value: Probe) -> Int {
    return value.value;
}

func replace_parameter(value: Probe) -> Void {
    value = Probe(99);
}

func drop_partial_array() -> Void {
    let values: Probe[3] = [Probe(7)];
}

func pop_text() -> String {
    let values: Vector(String) = ["White" + "Language"];
    return values.drop();
}

func main() -> Int {
    let partial: Int[4] = [7];
    if (partial[0] != 7 || partial[1] != 0 || partial[2] != 0 || partial[3] != 0) {
        print("FAIL: Partial fixed array was not zero-initialized");
        return 1;
    }

    drop_partial_array();
    if (DROPPED != 1) {
        print("FAIL: Fixed array did not release exactly its initialized reference");
        return 1;
    }

    let original: Probe = make_probe(10);
    replace_parameter(original);
    if (original.value != 10 || DROPPED != 2) {
        print("FAIL: Parameter reassignment corrupted caller ownership");
        return 1;
    }

    if (read_probe(make_probe(42)) != 42 || DROPPED != 3) {
        print("FAIL: Owned call argument was not released after the call");
        return 1;
    }

    let text: String = pop_text();
    let i: Int = 0;
    while (i < 128) {
        let noise: String = "allocation-" + i;
        i += 1;
    }
    if (text != "WhiteLanguage") {
        print("FAIL: Vector.drop returned a dangling reference");
        return 1;
    }

    print("PASS: Ownership and initialization contract");
    return 0;
}
