// Test: CORE_PROTOCOLS
// File: tests/language/generics/test_protocols.wl
// Focus: Self constraints, interface inheritance, custom display, cloning, and iteration.

import Hash, Equal, Comparable, Ordering, Display, Debug, Clone, Iterator, Iterable, IterationError from "protocol"

interface OrderedHash with Hash, Comparable {
}

class Key with OrderedHash, Display, Debug, Clone {
    let value: Int;

    init(value: Int) {
        self.value = value;
    }

    func equals(other: Key) -> Bool {
        return self.value == other.value;
    }

    func compare(other: Key) -> Ordering {
        if (self.value < other.value) { return Ordering.Less; }
        if (self.value > other.value) { return Ordering.Greater; }
        return Ordering.Equal;
    }

    func hash() -> Int {
        return self.value;
    }

    func display() -> String {
        return "key=" + self.value;
    }

    func debug() -> String {
        return "Key(value=" + self.value + ")";
    }

    func clone() -> Key {
        return Key(self.value);
    }
}

class Counter with Iterator(Int) {
    let current: Int;
    let end: Int;

    init(end: Int) {
        self.current = 0;
        self.end = end;
    }

    func next() -> Int? {
        if (self.current >= self.end) { throw IterationError.End; }
        let value: Int = self.current;
        self.current++;
        return value;
    }
}

class Range with Iterable(Int) {
    let end: Int;

    init(end: Int) {
        self.end = end;
    }

    func iterator() -> Iterator(Int) {
        return Counter(self.end);
    }
}

func equal<T: Equal>(left: T, right: T) -> Bool {
    return left.equals(right);
}

func copy<T: Clone>(value: T) -> T {
    return value.clone();
}

func compare<T: Comparable>(left: T, right: T) -> Ordering {
    return left.compare(right);
}

func hash<T: Hash>(value: T) -> Int {
    return value.hash();
}

func display<T: Display>(value: T) -> String {
    return value.display();
}

func debug<T: Debug>(value: T) -> String {
    return value.debug();
}

func main() -> Int {
    let value: Key = Key(7);
    let copied: Key = copy(value);
    if (!equal(value, copied) || value != copied || !(value < Key(8)) || value >= Key(8) || debug(value) != "Key(value=7)") {
        print("FAIL: Protocol constraints");
        return 1;
    }
    if (!equal(5, 5) || !equal(1.5, 1.5) || compare(4, 5) != Ordering.Less || hash("white") < 2 || display(12) != "12") {
        print("FAIL: Built-in protocol implementations");
        return 1;
    }
    let dynamic: Dict = Dict(8);
    dynamic.put(Key(9), "nine");
    let dynamic_value: String = dynamic.get(Key(9));
    if (dynamic_value != "nine") {
        print("FAIL: Dynamic Dict protocol key");
        return 1;
    }

    let source: Iterable(Int) = Range(2);
    let iterator: Iterator(Int) = source.iterator();
    let first: Int = iterator.next()?;
    catch(err) { print("FAIL: Iterator first value"); return 1; }
    let second: Int = iterator.next()?;
    catch(err) { print("FAIL: Iterator second value"); return 1; }
    if (first != 0 || second != 1) {
        print("FAIL: Iterator values");
        return 1;
    }
    let exhausted: Bool = false;
    let ignored: Int = 0;
    ignored = iterator.next()?;
    catch(err) {
        if (err != IterationError.End) { print("FAIL: Iterator error"); return 1; }
        exhausted = true;
    }
    if (!exhausted) {
        print("FAIL: Iterator exhaustion");
        return 1;
    }

    print(value);
    let shown: Display = value;
    print(shown);
    print("PASS: Core protocols");
    return 0;
}
