// Test: ANYPTR_STRING
// File: tests/language/types/test_anyptr_string.wl
// Focus: Restoring a live String object through AnyPtr without interpreting C text.

func main() -> Int {
    let original: String = "native " + String(42);
    let address: AnyPtr = original;
    let restored: String = address;
    if (restored != "native 42") { return 1; }

    let empty: String = "";
    let empty_address: AnyPtr = empty;
    let restored_empty: String = empty_address;
    if (restored_empty.length() != 0) { return 2; }

    let absent: AnyPtr = nullptr;
    if (absent is !nullptr) { return 3; }
    print("PASS: AnyPtr String restoration");
    return 0;
}
