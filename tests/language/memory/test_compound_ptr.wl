// Test: COMPOUND_ASSIGNMENT_POINTER
// File: tests/language/memory/test_compound_ptr.wl
// Focus: Compound arithmetic (+=, -=) on direct variables, struct fields, and dereferenced pointers.


struct Point(x: Int, y: Int)

func main() -> Int {
    // variable compound
    let a: Int = 10;
    a += 5;
    
    // struct field compound
    let p: Point = Point(x=10, y=20);
    p.x += 10;
    
    // pointer dereference compound
    let ptr val_ptr: Int = ref a;
    (deref val_ptr) += 100;

    if (a == 115 && p.x == 20) {
        print("PASS: Compound assignment across different memory types");
    } else {
        print("FAIL: Compound assignment calculation error");
    }
    return 0;
}
