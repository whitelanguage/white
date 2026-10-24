// Test: STRUCT_OVERRIDE
// File: tests/language/memory/test_struct_override.wl
// Focus: Explicit arguments release managed values written by the initializer body.

let CREATED: Int = 0;
let DROPPED: Int = 0;

class Probe {
    init() { CREATED++; }
    deinit() { DROPPED++; }
}

struct Holder(probe: Probe = Probe()) {
    this.probe = Probe();
}

func check_scope() -> Bool {
    let value = Holder(probe=Probe());
    return CREATED == 2 && DROPPED == 1;
}

func main() -> Int {
    if (!check_scope() || CREATED != 2 || DROPPED != 2) {
        print("FAIL: struct field replacement", CREATED, DROPPED);
        return 1;
    }
    print("PASS: struct field replacement");
    return 0;
}
