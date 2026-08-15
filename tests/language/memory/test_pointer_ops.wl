// Test: POINTER_REFERENCE_DEREF
// File: tests/language/memory/test_pointer_ops.wl
// Focus: Memory addressing using 'ref' and value mutation via 'deref'.


func identity(ptr value: Int) -> ptr Int {
    return value;
}

func main() -> Int {
    let data: Int = 42;
    let ptr p: Int = identity(ref data);
    let pair: Int[2] = [1, 2];
    let ptr pair_address: Int[2] = ref pair;
    let pointers: Vector(ptr Int) = [p];
    let view: Array(ptr Int) = pointers[:];
    
    // mutate original value via pointer
    deref p = 100;

    if (data == 100 && deref view[0] == 100 && pair_address is !nullptr) {
        print("PASS: Pointer reference and dereference");
    } else {
        print("FAIL: Pointer mutation failed. Expected 100, got: " + data);
    }
    return 0;
}
