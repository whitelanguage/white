// Test: STRUCT_DEFAULTS
// File: tests/language/types/test_struct_defaults.wl
// Focus: Required fields, per-instance defaults, generic defaults and explicit overrides.

let CREATED: Int = 0;
let TRACE: Int = 0;
const DEFAULT_SIZE: Int = 7;

func next_size() -> Int {
    CREATED++;
    return DEFAULT_SIZE;
}

struct Config(name: String, size: Int = next_size(), values: Vector(Int) = [], note: Optional(String) = null)
struct Box<T>(value: T, rest: Vector(T) = [])
struct Legacy(count: Int = 3, total: Int = 0) {
    this.total = this.count + 1;
}

func step(value: Int) -> Int {
    TRACE = TRACE * 10 + value;
    return value;
}

struct Ordered(arg: Int, first: Int = step(1), second: Int = step(2))

func main() -> Int {
    let DEFAULT_SIZE = 99;
    let first = Config("first");
    let second = Config(name="second", size=10);
    if (first.size != 7 || second.size != 10 || CREATED != 1 || first.note is !null) {
        print("FAIL: defaults or explicit overrides");
        return 1;
    }
    first.values.append(5);
    if (second.values.length() != 0 || first.values.length() != 1) {
        print("FAIL: default containers share storage");
        return 1;
    }

    let box: Box(String) = Box("hello");
    box.rest.append("world");
    let other = Box<Int>(42);
    if (box.value != "hello" || box.rest[0] != "world" || other.rest.length() != 0) {
        print("FAIL: generic defaults");
        return 1;
    }
    let legacy = Legacy();
    if (legacy.count != 3 || legacy.total != 4) {
        print("FAIL: initializer body cannot read a field default");
        return 1;
    }
    let ordered = Ordered(step(3));
    if (TRACE != 123 || ordered.arg != 3 || ordered.first != 1 || ordered.second != 2) {
        print("FAIL: default evaluation order");
        return 1;
    }
    print("PASS: explicit struct defaults");
    return 0;
}
