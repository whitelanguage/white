// Test: TYPE_ALIAS_CALL
// File: tests/language/types/test_type_alias_call.wl
// Focus: Renamed intrinsic imports retain type operands without changing ordinary calls.

import is_type as exact, is_instance as instance from "builtin"

class Base {}
class Child(Base) {}

func ordinary(value: Int, message: String) -> String {
    return message;
}

func positive(value: Int) -> Bool { return value > 0; }
func compare(value: Int, other: Int) -> Bool { return value > other; }

func shadow_test() -> Bool {
    let is_type = positive;
    if (is_type(10)) { return true; }
    return false;
}

func shadow_pair() -> Bool {
    let is_type = compare;
    if (is_type(10, 5)) { return true; }
    return false;
}

func main() -> Int {
    let values: Vector(Int) = [1, 2];
    if (!exact(values, Vector(Int)) || exact(values, Vector(String))) { return 1; }
    let child = Child();
    if (!instance(child, Base) || !exact(child, Child)) { return 2; }
    let is_type = ordinary;
    if (is_type(10, "ok") != "ok") { return 3; }
    if (!shadow_test() || !shadow_pair()) { return 4; }
    print("PASS: renamed type checks");
    return 0;
}
