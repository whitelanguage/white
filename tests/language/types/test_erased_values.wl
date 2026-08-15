// Test: ERASED_VALUE_RESTORE
// File: tests/language/types/test_erased_values.wl
// Focus: Restoring classes and functions after their concrete type has been erased.

class Base { func value() -> Int { return 1; } }
class Child(Base) { func value() -> Int { return 2; } }

func make_class() -> Class { return Child(); }
func answer() -> Int { return 42; }
func make_function() -> Function { return answer; }

func main() -> Int {
    let object: Base = make_class();
    let callback: Function() -> Int = make_function();
    if (object.value() != 2 || callback() != 42) { print("FAIL: erased value restore"); return 1; }
    print("PASS: erased value restore");
    return 0;
}
