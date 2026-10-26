// Test: READ_SYMBOL
// File: tests/language/generics/test_read_symbol.wl
// Focus: Keeping a generic user signature separate from the POSIX read declaration.

class Box<T> {
    let value: T;
    init(value: T) { self.value = value; }
}

func read(value: Optional(Box(Int))) -> Int {
    if (value is null) { return 0; }
    return value.value;
}

func main() -> Int {
    let value: Box(Int) = Box(42);
    if (read(value) != 42 || read(null) != 0) {
        print("FAIL: user read signature");
        return 1;
    }
    print("PASS: user read signature");
    return 0;
}
