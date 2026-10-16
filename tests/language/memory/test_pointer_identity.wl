// Test: POINTER_IDENTITY
// File: tests/language/memory/test_pointer_identity.wl
// Focus: Address identity stays separate from pointee and String value equality.

func main() -> Int {
    let left: Int = 42;
    let right: Int = 42;
    let ptr first: Int = ref left;
    let ptr alias: Int = first;
    let ptr other: Int = ref right;
    if (first is !alias || first is other || first is nullptr) {
        print("FAIL: typed pointer identity");
        return 1;
    }
    if (AnyPtr(first) is !AnyPtr(alias) || AnyPtr(first) is AnyPtr(other)) {
        print("FAIL: AnyPtr identity");
        return 1;
    }
    let ptr empty: Int = nullptr;
    if (empty is !nullptr || left != right) {
        print("FAIL: null identity or integer value equality");
        return 1;
    }
    let text: String = "same"[:];
    let copy: String = "same"[:];
    if (text != copy || text is copy) {
        print("FAIL: String value equality or identity");
        return 1;
    }
    print("PASS: pointer identity and value equality");
    return 0;
}
