// Test: LOGIC_CHAIN
// File: tests/language/control/test_logic_chain.wl
// Focus: Lowering long short-circuit expressions without retaining a large stack frame per operand.

let calls: Int = 0;

func hit(value: Bool) -> Bool {
    calls++;
    return value;
}

func matches(value: Int) -> Bool {
    return value == 0 || value == 1 || value == 2 || value == 3 || value == 4 || value == 5 ||
           value == 6 || value == 7 || value == 8 || value == 9 || value == 10 || value == 11 ||
           value == 12 || value == 13 || value == 14 || value == 15 || value == 16 || value == 17 ||
           value == 18 || value == 19 || value == 20 || value == 21 || value == 22 || value == 23 ||
           value == 24 || value == 25 || value == 26 || value == 27 || value == 28 || value == 29 ||
           value == 30 || value == 31 || value == 32 || value == 33 || value == 34 || value == 35 ||
           value == 36 || value == 37 || value == 38 || value == 39 || value == 40 || value == 41 ||
           value == 42 || value == 43 || value == 44 || value == 45 || value == 46 || value == 47;
}

func main() -> Int {
    if (!matches(0) || !matches(47) || matches(48)) {
        print("FAIL: logic chain");
        return 1;
    }

    if (hit(true) || hit(false)) { }
    if (hit(false) && hit(true)) { }
    if (calls != 2) {
        print("FAIL: short circuit calls");
        return 1;
    }

    print("PASS: logic chain");
    return 0;
}
