// Test: VOID_RETURN_VALUE
// File: tests/diagnostics/failures/test_void_value.wl
// Focus: Void rejects a return expression before null conversion or WIR emission.
// Expected Error: "TypeError: Void function cannot return a value."

func value() -> Void {
    return null;
}

func main() -> Int {
    value();
    return 0;
}
