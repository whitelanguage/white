// Test: TYPE_CHECK_ARC
// File: tests/language/memory/test_type_check_arc.wl
// Focus: Type checks and narrowed union copies release their temporary owners.

let DROPPED: Int = 0;

class Base {}

class Probe(Base) {
    deinit() { DROPPED++; }
}

class Holder {
    let value: Int | Probe | Null;
    init(value: Probe) { self.value = value; }
}

func inspect(value: Int | Probe | Null) -> Int {
    if (value is null) { return 0; }
    let copy: Int | Probe = value;
    if (is_type(copy, Int)) { return copy; }
    return 1;
}

func main() -> Int {
    let i = 0;
    while (i < 100) {
        if (!is_type(Probe(), Probe) || !is_instance(Probe(), Base)) { return 1; }
        if (inspect(Holder(Probe()).value) != 1) { return 2; }
        i++;
    }
    if (DROPPED != 300) {
        print("FAIL: type check ownership", DROPPED);
        return 3;
    }
    print("PASS: type check ownership");
    return 0;
}
