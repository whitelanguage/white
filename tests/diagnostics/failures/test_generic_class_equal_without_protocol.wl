// Test: GENERIC_CLASS_EQUAL_WITHOUT_PROTOCOL
// File: tests/diagnostics/failures/test_generic_class_equal_without_protocol.wl
// Focus: Generic Class instances do not gain implicit address equality.
// Expected Error: "TypeError: Class equality requires matching types implementing Equal. Use 'is' or 'is !' for identity."

class Box<T> {
    let value: T;
    init(value: T) { self.value = value; }
}

func main() -> Int {
    let box: Box(Int) = Box(1);
    let same = box == box;
    return 0;
}
