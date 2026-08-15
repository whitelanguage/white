// Test: CONST_ELEMENT_WRITE
// File: tests/diagnostics/failures/test_const_element.wl
// Focus: Propagating const access when an object is copied into another binding.
// Expected Error: "TypeError: Cannot modify value through const access 'item'"

class Box { let value: Int = 0; }

func main() -> Int {
    const boxes: Vector(Box) = [Box()];
    let item: Box = boxes[0];
    item.value = 1;
    return 0;
}
