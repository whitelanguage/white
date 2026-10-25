// Test: POINTER_EQUALITY
// File: tests/language/memory/test_pointer_equal.wl
// Focus: Comparing typed and erased pointers without reading their pointees.

func main() -> Int {
    let first = 1;
    let second = 1;
    let ptr a: Int = ref first;
    let ptr alias: Int = a;
    let ptr b: Int = ref second;

    if (a != alias || a == b || AnyPtr(a) != AnyPtr(alias) || AnyPtr(a) == AnyPtr(b)) {
        print("FAIL: pointer equality");
        return 1;
    }

    print("PASS: pointer equality");
    return 0;
}
