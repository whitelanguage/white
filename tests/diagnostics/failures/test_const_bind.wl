// Test: CONST_METHOD_BIND
// File: tests/diagnostics/failures/test_const_bind.wl
// Focus: Preventing a method value from bypassing a const receiver.
// Expected Error: "TypeError: Cannot bind a method through const value"

class Box { func set() -> Void { } }

func main() -> Int {
    const box: Box = Box();
    let setter: Method() -> Void = box.set;
    setter();
    return 0;
}
