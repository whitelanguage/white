// Test: OPTIONAL_METHOD
// File: tests/diagnostics/failures/test_optional_method.wl
// Focus: Field checks are not inherited by the next method body.
// Expected Error: "TypeError: Type mismatch. Expected Int, got (Null | Int)."

class Holder {
    let value: Optional(Int);
    init() { self.value = 42; }
    func checked() -> Int {
        if (self.value is null) { return 0; }
        return self.value;
    }
    func unchecked() -> Int { return self.value; }
}
func main() -> Int { return 0; }
