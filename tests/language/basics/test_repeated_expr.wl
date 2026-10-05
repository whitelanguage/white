// Test: REPEATED_INTEGER_EXPRESSIONS
// File: tests/language/basics/test_repeated_expr.wl
// Focus: Reused arithmetic, operand order, narrowing and mutation between reads.

func calculate(a: Int, b: Int) -> Int {
    let product = a * b;
    let repeated = b * a;
    let first = product ^ a;
    let second = repeated ^ a;
    return first + second + (a - b) + (b - a);
}

func wide(a: Int128, b: Int128) -> Int128 {
    let product = a * b;
    let repeated = b * a;
    return product + repeated;
}

func narrow(value: Long) -> Long {
    let a = Int(value);
    let b = Int16(value);
    let c = Int(value);
    return Long(a) + Long(b) + Long(c);
}

func reads(ptr value: Int) -> Int {
    let first = value[0] + 3;
    value[0] = 20;
    let second = value[0] + 3;
    return first + second;
}

func main() -> Int {
    let i = -100;
    while (i < 100) {
        if (calculate(i, 7) != 2 * ((i * 7) ^ i)) {
            print("FAIL: repeated integer expressions or operand order");
            return 1;
        }
        i++;
    }
    if (wide(12345678901234567890LL, 7LL) != 172839504617283950460LL || narrow(-1234L) != -3702L) {
        print("FAIL: repeated wide or narrowed expressions");
        return 1;
    }
    let value = 10;
    if (reads(ref value) != 36 || value != 20) {
        print("FAIL: expression reuse ignored a changed memory value");
        return 1;
    }
    print("PASS: repeated integer expressions");
    return 0;
}
