// Test: RUNTIME_NULL_ACCESS
// File: tests/diagnostics/failures/test_null_access.wl
// Focus: Reporting a null class access before reading object storage.
// Expected Error: "RuntimeError: Null pointer dereference"

class Box {
    let value: Int = 1;
}

func main() -> Int {
    let box: Box = null;
    print(box.value);
    return 0;
}
