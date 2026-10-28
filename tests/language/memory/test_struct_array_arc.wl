// Test: STRUCT_ARRAY_ARC
// File: tests/language/memory/test_struct_array_arc.wl
// Focus: borrowed inline arrays and cleanup after a later default element fails.

let CREATED: Int = 0;
let DROPPED: Int = 0;

class Probe {
    init() { CREATED++; }
    deinit() { DROPPED++; }
}

struct Holder(values: Probe[2] = [Probe(), Probe()])

func fail() -> Probe? {
    throw Error.InvalidArgument;
}

struct Interrupted(values: Probe[2] = [Probe(), fail()?])

func check_copy() -> Bool {
    let values: Probe[2] = [Probe(), Probe()];
    let holder = Holder(values);
    let copy = holder;
    return CREATED == 2 && DROPPED == 0;
}

func check_default() -> Bool {
    let holder = Holder();
    return CREATED == 4 && DROPPED == 2;
}

func check_failure() -> Bool {
    let holder = Interrupted();
    catch(err) {
        return CREATED == DROPPED;
    }
    return false;
}

func main() -> Int {
    if (!check_copy() || CREATED != 2 || DROPPED != 2) {
        print("FAIL: borrowed fixed array", CREATED, DROPPED);
        return 1;
    }
    if (!check_default() || CREATED != 4 || DROPPED != 4) {
        print("FAIL: fixed array default", CREATED, DROPPED);
        return 2;
    }
    if (!check_failure() || CREATED != 5 || DROPPED != 5) {
        print("FAIL: partial fixed array cleanup", CREATED, DROPPED);
        return 3;
    }
    print("PASS: fixed array field ownership");
    return 0;
}
