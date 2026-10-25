// Test: LITERAL_DROP
// File: tests/language/collections/test_literal_drop.wl
// Focus: Releasing class elements owned by temporary dictionary literals.

let dropped: Int = 0;

class Probe {
    deinit() {
        dropped++;
    }
}

func count(values: Dict) -> Int {
    return values.size;
}

func main() -> Int {
    let size = count({"probe": Probe()});
    if (size != 1 || dropped != 1) {
        print("FAIL: temporary dictionary element was not released");
        return 1;
    }

    print("PASS: temporary dictionary release");
    return 0;
}
