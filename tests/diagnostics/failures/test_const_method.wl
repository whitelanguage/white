// Test: CONST_MUTATING_METHOD
// File: tests/diagnostics/failures/test_const_method.wl
// Focus: Rejecting mutating method calls through const values.
// Expected Error: "TypeError: Cannot call mutating method 'set' through const value"

class Box { let value: Int = 0; func set(value: Int) -> Void { self.value = value; } }
func main() -> Int { const box: Box = Box(); box.set(1); return 0; }
