// Test: POINTER_EQUALITY
// File: tests/language/memory/test_pointer_equality.wl
// Focus: Equality compares matching pointer types without numeric promotion.

func main() -> Int {
    let left: Int = 42;
    let right: Int = 42;
    let ptr first: Int = ref left;
    let ptr alias: Int = ref left;
    let ptr other: Int = ref right;
    if (first != alias || first == other) {
        print("FAIL: typed pointer equality");
        return 1;
    }
    if (AnyPtr(first) != AnyPtr(alias) || AnyPtr(first) == AnyPtr(other)) {
        print("FAIL: erased pointer equality");
        return 1;
    }
    print("PASS: typed and erased pointer equality");
    return 0;
}
