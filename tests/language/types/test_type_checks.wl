// Test: TYPE_CHECKS
// File: tests/language/types/test_type_checks.wl
// Focus: Exact type tests, class inheritance and residual union narrowing.

type Int as Count;
type Number = Int;
type Owner = Duck;
type Function(Int) -> Int as Unary;
type ptr Int as IntPtr;
struct Point(x: Int, y: Int)

func increment(value: Int) -> Int { return value + 1; }
func erased_point() -> Struct { return Point(1, 2); }
func erased_function() -> Function { return increment; }

interface Known {
    func identity() -> Int;
}

class Animal {
    func voice() -> String { return "animal"; }
}

class Duck(Animal) with Known {
    func quack() -> String { return "quack"; }
    func identity() -> Int { return 7; }
}

class Box<T>(Animal) {
    let value: T;
    init(value: T) { self.value = value; }
}

func describe(value: Int | String | Null) -> String {
    if (value is null) { return "missing"; }
    let remaining: Int | String = value;
    if (is_type(remaining, String)) {
        return remaining;
    } else {
        let count: Int = remaining;
        return String(count);
    }
}

func classify(value: Int | String | Bool | Null) -> Int {
    if (value is null) { return 0; }
    let remaining: Int | String | Bool = value;
    if (is_type(remaining, Int)) { return remaining; }
    if (is_type(remaining, String)) { return remaining.length(); }
    if remaining { return 1; }
    return 2;
}

func animal_test(value: Animal) -> Bool {
    if (is_type(value, Animal)) { return false; }
    if (is_instance(value, Duck)) {
        return value.quack() == "quack";
    }
    return false;
}

func generic_test(value: Animal) -> Bool {
    return is_instance(value, Animal);
}

func main() -> Int {
    if (!is_type(10, Int) || !is_type(10, Count) || is_type(10, Long)) { return 1; }
    if (!is_type("hello", String) || !is_type(null, Null)) { return 2; }
    let number = Number(10);
    if (!is_type(number, Number) || is_type(number, Int)) { return 3; }
    if (describe("hello") != "hello" || describe(42) != "42" || describe(null) != "missing") { return 4; }
    let duck = Duck();
    let animal: Animal = duck;
    if (!is_type(animal, Duck) || is_type(animal, Animal)) { return 5; }
    if (!is_instance(duck, Animal) || !is_instance(duck, Duck) || is_instance(Animal(), Duck)) { return 6; }
    if (!animal_test(animal)) { return 7; }
    let optional: Optional(Animal) = animal;
    if (is_instance(optional, Duck)) {
        if (optional.quack() != "quack") { return 8; }
    } else { return 9; }
    optional = null;
    if (is_instance(optional, Animal) || !is_type(optional, Null)) { return 10; }
    let box = Box<Int>(42);
    if (!generic_test(box) || !is_type(box, Box(Int))) { return 11; }
    let values: Vector(Int) = [1, 2];
    if (!is_type(values, Vector(Int)) || is_type(values, Vector(String))) { return 12; }
    let view: Known = duck;
    if (is_type(view, Known) || !is_type(view, Duck)) { return 13; }
    if (is_instance(view, Duck)) {
        if (view.quack() != "quack") { return 14; }
    } else { return 15; }
    let widened: Optional(Known) = duck;
    if (widened is null || widened.identity() != 7) { return 16; }
    let narrow: Optional(Duck) = duck;
    let base: Optional(Animal) = narrow;
    let known: Optional(Known) = narrow;
    if (!is_type(base, Duck) || known is null || known.identity() != 7) { return 17; }
    narrow = null;
    base = narrow;
    known = narrow;
    if (!is_type(base, Null) || !is_type(known, Null)) { return 18; }
    let exact: Animal | Known | Duck = duck;
    if (!is_type(exact, Duck)) { return 19; }
    let owner = Owner(duck);
    if (!is_type(owner, Owner) || is_type(owner, Duck) || !is_instance(owner, Animal)) { return 20; }
    if (!is_type(erased_point(), Point) || is_type(erased_point(), Duck)) { return 21; }
    if (!is_type(erased_function(), Unary) || is_type(erased_function(), Int)) { return 22; }
    let count = 10;
    let ptr address: Int = ref count;
    if (!is_type(address, IntPtr)) { return 23; }
    if (classify(42) != 42 || classify("hello") != 5 || classify(true) != 1 || classify(false) != 2 || classify(null) != 0) { return 24; }
    print("PASS: type checks");
    return 0;
}
