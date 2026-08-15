// Test: CONST_RECEIVER_ESCAPE
// File: tests/diagnostics/failures/test_const_escape.wl
// Focus: Treating methods that pass self to mutable code as mutating.
// Expected Error: "TypeError: Cannot call mutating method 'touch' through const value"

class Box {
    let value: Int = 0;
    func touch() -> Void { mutate(self); }
}

func mutate(box: Box) -> Void { box.value = 1; }

func main() -> Int {
    const box: Box = Box();
    box.touch();
    return 0;
}
