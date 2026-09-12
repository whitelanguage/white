// Test: VARIADIC_CONSTRUCTION_AND_SUPER_CALLS
// File: tests/language/control/test_variadic_super.wl
// Focus: Packing variadic arguments for class initializers and parent method calls.

func join(parts: String..., sep: String = "-") -> String {
    let result: String = "";
    let i: Int = 0;
    while (i < parts.length()) {
        if (i > 0) { result += sep; }
        result += parts[i];
        i++;
    }
    return result;
}

class BaseJoiner {
    let value: String;

    init(parts: String..., sep: String = ":") {
        self.value = join(parts..., sep=sep);
    }

    func merge(parts: String..., sep: String = ",") -> String {
        return self.value + sep + join(parts..., sep=sep);
    }
}

class Joiner(BaseJoiner) {
    init(parts: String..., sep: String = "/") {
        super.init(parts..., sep=sep);
    }

    func parent_merge(parts: String..., sep: String = "|") -> String {
        return super.merge(parts..., sep=sep);
    }
}

func main() -> Int {
    let joiner = Joiner("a", "b", sep="/");
    if (joiner.parent_merge("c", "d", sep="|") != "a/b|c|d") {
        print("FAIL: Variadic constructor or parent call");
        return 1;
    }
    print("PASS: Variadic constructor and parent call");
    return 0;
}
