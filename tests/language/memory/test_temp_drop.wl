// Test: TEMPORARY_DROP
// File: tests/language/memory/test_temp_drop.wl
// Focus: Dropping unused class and container return values at the end of an expression statement.


let DROPPED: Int = 0;

class Probe {
    deinit() {
        DROPPED += 1;
    }
}

func make_probe() -> Probe {
    return Probe();
}

func make_probes() -> Vector(Probe) {
    return [Probe(), Probe()];
}

func main() -> Int {
    make_probe();
    if (DROPPED != 1) {
        print("FAIL: Unused class return value was not dropped");
        return 1;
    }

    Probe();
    if (DROPPED != 2) {
        print("FAIL: Unused class temporary was not dropped");
        return 1;
    }

    make_probes();
    if (DROPPED != 4) {
        print("FAIL: Unused Vector return value was not dropped");
        return 1;
    }

    print("PASS: Unused owned values are dropped");
    return 0;
}
