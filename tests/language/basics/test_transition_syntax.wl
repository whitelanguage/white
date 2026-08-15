// Test: TRANSITION_SYNTAX
// File: tests/language/basics/test_transition_syntax.wl
// Focus: Colon annotations, inferred locals, func methods, and callable return syntax.

const TRANSITION_VERSION = 34;

interface Named {
    func name(prefix: String) -> String;
}

struct Pair(left: Int, right -> Int)

class Box<T> with Named {
    let value: T;
    let label -> String;
    let enabled = true;

    init(value: T, label -> String) {
        self.value = value;
        self.label = label;
    }

    func name(prefix: String) -> String {
        return prefix + self.label;
    }

    func get() -> T {
        return self.value;
    }

    func echo<U>(value: U) -> U {
        return value;
    }
}

func increment(value: Int) -> Int {
    return value + 1;
}

func forty_two() -> Int {
    return 42;
}

func apply(value: Int, operation: Function(Int) -> Int) -> Int {
    return operation(value);
}

func main() -> Int {
    let box = Box(7, "White");
    let inferred = box.get();
    let typed: Int = apply(inferred, increment);
    let legacy -> Int = 9;
    let pair: Pair = Pair(left=typed, right=legacy);
    let bound: Method(String) -> String = box.name;
    let old_bound -> Method(String, String) = box.name;
    let producer: Function() -> Int = forty_two;
    let echoed = box.echo(" Language");
    let sum = 0;

    for (let i = 0; i < 3; i++) {
        sum += i;
    }

    if (pair.left != 8 || pair.right != 9 || sum != 3 || producer() != 42 ||
        TRANSITION_VERSION != 34 || !box.enabled ||
        bound("Hello ") != "Hello White" || old_bound("Hi ") != "Hi White" ||
        echoed != " Language") {
        print("FAIL: transition syntax");
        return 1;
    }

    print("PASS: transition syntax");
    return 0;
}
