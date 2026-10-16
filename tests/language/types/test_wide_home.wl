// Test: WIDE_HOME
// File: tests/language/types/test_wide_home.wl
// Focus: Commit cached Int128 pairs before returns, stores and argument copies.

struct Record(value: UInt128)

func limit(kind: Int) -> UInt128 {
    if (kind == 1) { return UInt128(255); }
    return UInt128(18446744073709551615UL);
}

func digits(text: String) -> UInt128 {
    let value: UInt128 = UInt128(0);
    let i: Int = 0;
    while (i < text.length()) {
        value = value * UInt128(10U) + UInt128(Int(text[i]) - 48);
        i++;
    }
    return value;
}

func accept(value: UInt128) -> Bool {
    return value == 256ULL;
}

func outside(text: String, kind: Int) -> Bool {
    let value = digits(text);
    let max = limit(kind);
    return max != UInt128(0) && value > max;
}

func main() -> Int {
    if (limit(1) != 255ULL || digits("0") != 0ULL || digits("61") != 61ULL ||
        outside("61", 1) || outside("255", 1) || !outside("256", 1)) {
        print("FAIL: Int128 returns and range checks");
        return 1;
    }

    let value = digits("255") + 1ULL;
    let record = Record(value);
    let values: Vector(UInt128) = [value];
    if (record.value != 256ULL || values[0] != 256ULL || !accept(value)) {
        print("FAIL: Int128 argument and container copies");
        return 1;
    }

    print("PASS: Int128 home synchronization");
    return 0;
}
