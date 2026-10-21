// Test: NULL_TYPE
// File: tests/language/types/test_null_type.wl
// Focus: Null is a singleton value type, distinct from Void and nullptr.

type Null as Empty;
const EMPTY: Null = null;

func empty() -> Null {
    return null;
}

func same(value: Null) -> Null {
    return value;
}

func main() -> Int {
    let value: Empty = empty();
    let copied: Null = same(value);
    if (copied is !null || EMPTY is !null) {
        print("FAIL: Null lost its only value");
        return 1;
    }

    print("PASS: Null type");
    return 0;
}
