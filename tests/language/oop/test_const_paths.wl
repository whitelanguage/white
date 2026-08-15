// Test: CONST_ACCESS_PATHS
// File: tests/language/oop/test_const_paths.wl
// Focus: const getters and mutable aliases after rebinding.

class Box {
    let value: Int = 7;
    func get() -> Int { return self.value; }
    func set(value: Int) -> Void { self.value = value; }
}

func main() -> Int {
    const original: Box = Box();
    if (original.get() != 7) { print("FAIL: const getter"); return 1; }
    let alias: Box = original;
    alias = Box();
    alias.set(9);
    if (alias.get() != 9 || original.get() != 7) { print("FAIL: const alias rebinding"); return 1; }
    print("PASS: const access paths");
    return 0;
}
