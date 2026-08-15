// Test: LOCAL_FUNCTION_RECURSION
// File: tests/language/control/test_local_recursion.wl
// Focus: Direct recursion from a named local function.

func main() -> Int {
    func factorial(value: Int) -> Int {
        if (value <= 1) { return 1; }
        return value * factorial(value - 1);
    }
    if (factorial(6) != 720) { print("FAIL: local recursion"); return 1; }
    print("PASS: local recursion");
    return 0;
}
