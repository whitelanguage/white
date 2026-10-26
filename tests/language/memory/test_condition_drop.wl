// Test: CONDITION_DROP
// File: tests/language/memory/test_condition_drop.wl
// Focus: Releasing temporary receivers on loop, branch, and short-circuit paths.

let made: Int = 0;
let dropped: Int = 0;

class Probe {
    let active: Bool;
    let text: String;

    init(active: Bool) {
        made++;
        self.active = active;
        self.text = "alive";
    }
    deinit() { dropped++; }
}

func print_temporary_map() -> Void {
    print({"probe": Probe(true)});
}

func main() -> Int {
    let i: Int = 0;
    while (Probe(i < 3).active) { i++; }
    if (made != 4 || dropped != 4) {
        print("FAIL: while condition receiver");
        return 1;
    }
    for (let n: Int = 0; Probe(n < 3).active; n++) {}
    if (made != 8 || dropped != 8) {
        print("FAIL: for condition receiver");
        return 1;
    }
    if (Probe(true).active) {
        if (dropped != made) { print("FAIL: branch condition receiver"); return 1; }
    }
    let short: Bool = Probe(false).active && Probe(true).active;
    let other: Bool = Probe(true).active || Probe(false).active;
    if (short || !other || made != 11 || dropped != made) {
        print("FAIL: short-circuit receiver");
        return 1;
    }
    let text: String = Probe(true).text;
    if (text != "alive" || dropped != made) {
        print("FAIL: managed field outlived its receiver");
        return 1;
    }
    print_temporary_map();
    if (dropped != made) {
        print("FAIL: dictionary literal receiver");
        return 1;
    }
    print("PASS: condition temporary ownership");
    return 0;
}
