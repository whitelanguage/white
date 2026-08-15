// Test: CONST_DEEP_WRITE
// File: tests/diagnostics/failures/test_const_write.wl
// Focus: Rejecting mutation through a const access path.
// Expected Error: "TypeError: Cannot modify value through const access 'box'"

class Box { let value: Int = 0; }
func main() -> Int { const box: Box = Box(); box.value = 1; return 0; }
