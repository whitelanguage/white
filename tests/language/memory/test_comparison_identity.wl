// Test: COMPARISON_IDENTITY
// File: tests/language/memory/test_comparison_identity.wl
// Focus: Class protocols compare values, explicit pointers and Class aliases compare identity.

import Equal from "protocol"


class Item {
    let value: Int;

    init(value: Int) { self.value = value; }
}

class Key with Equal {
    let value: Int;

    init(value: Int) { self.value = value; }

    func equals(other: Key) -> Bool {
        return self.value == other.value;
    }
}

struct Point(x: Int)
struct Box<T>(value: T)

func main() -> Int {
    let item = Item(1);
    let alias = item;
    let other = Item(1);
    if (item is !alias || item is other) {
        print("FAIL: Class identity");
        return 1;
    }

    let key = Key(2);
    let equal = Key(2);
    let different = Key(3);
    if (!(key == equal) || key != equal || !(key != different) || key == different || key is equal) {
        print("FAIL: Equal protocol or Class identity");
        return 1;
    }

    let point = Point(4);
    let copy = point;
    let ptr first: Point = ref point;
    let ptr same: Point = ref point;
    let ptr second: Point = ref copy;
    if (first is !same || first is second) {
        print("FAIL: Struct pointer identity");
        return 1;
    }

    let boxed: Box(Int) = Box(5);
    let ptr boxed_ptr: Box(Int) = ref boxed;
    if (boxed_ptr is nullptr || boxed_ptr.value != 5) {
        print("FAIL: generic Struct pointer");
        return 1;
    }

    print("PASS: comparison and identity");
    return 0;
}
