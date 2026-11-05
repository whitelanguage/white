// Test: FALLIBLE_RETURN_POINTER
// File: tests/diagnostics/failures/test_fallible_return_pointer.wl
// Focus: An incompatible pointer return produces a source diagnostic.
// Expected Error: "TypeError: Type mismatch. Expected Ptr<Byte>, got Ptr<Int>"

func convert(ptr value: Int) -> ptr Byte? {
    return value;
}

func main() -> Int {
    return 0;
}
