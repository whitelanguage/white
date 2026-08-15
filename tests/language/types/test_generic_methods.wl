// Test: GENERIC_METHODS
// File: tests/language/types/test_generic_methods.wl
// Focus: Generic methods, parameterized interfaces, constraints, inheritance, and inferred instances.

interface Reader<T> {
    func read() -> T;
}

class Box<T> with Reader(T) {
    let value: T;

    init(value: T) {
        self.value = value;
    }

    func read() -> T {
        return self.value;
    }

    func choose<U>(value: U) -> U {
        return value;
    }

    func require<U>(value: U, fail: Bool) -> U? {
        if fail { throw Error.InvalidArgument; }
        return value;
    }
}

class Child<T>(Box(T)) {
    init(value: T) {
        super.init(value);
    }
}

func read_int<T: Reader(Int)>(value: T) -> Int {
    let reader: Reader(Int) = value;
    return reader.read();
}

func identity<T>(value: T) -> T {
    return value;
}

func main() -> Int {
    let box: Auto = Box(17);
    let child: Child(String) = Child("white");
    let selected: Auto = box.choose("language");
    let choose_int: Method(Int) -> Int = box.choose<Int>;
    let identity_int: Function(Int) -> Int = identity<Int>;
    let required: String = box.require("checked", false)?;
    catch(err) {
        print("FAIL: Generic fallible method");
        return 1;
    }

    if (read_int(box) != 17 || child.read() != "white" || selected != "language" || box.choose<Int>(23) != 23 || choose_int(29) != 29 || identity_int(31) != 31 || required != "checked") {
        print("FAIL: Generic methods and interfaces");
        return 1;
    }

    print("PASS: Generic methods and interfaces");
    return 0;
}
