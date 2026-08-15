// Test: NULL_POINTER_SAFETY
// File: tests/language/memory/test_null_safety.wl
// Focus: 'null' for reference types, 'nullptr' for raw pointers, and 'is' operator checks.


struct Box(val: Int)

func main() -> Int {
    let s: String = null;
    let b: Box = null;
    let ptr p: Int = nullptr;
    
    let is_null_ok: Bool = (s is null) && (b is null) && (p is nullptr);
    
    s = "Not Null";
    let is_not_null_ok: Bool = (s is ! null);

    if (is_null_ok && is_not_null_ok) {
        print("PASS: Null and nullptr safety semantics");
    } else {
        print("FAIL: Null safety check mismatch");
    }
    return 0;
}
