// Test: CONST_ALIAS_WRITE
// File: tests/diagnostics/failures/test_const_alias.wl
// Focus: Preserving const access when a const object is copied into another binding.
// Expected Error: "TypeError: Cannot modify value through const access 'alias'"

class Box { let value: Int = 0; }

func main() -> Int {
    const box: Box = Box();
    let alias: Box = box;
    alias.value = 1;
    return 0;
}
