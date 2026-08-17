// Test: NATIVE_VARIADIC
// File: tests/language/control/test_variadic.wl
// Focus: Native variadic packs, defaults, expansion, generics, methods, and escaped storage.

func join_parts(parts: String..., sep: String = "-") -> String {
    let result: String = "";
    let i: Int = 0;
    while (i < parts.length()) {
        if (i > 0) { result += sep; }
        result += parts[i];
        i++;
    }
    return result;
}

func collect(values: String...) -> Array(String) {
    return values;
}

func count<T>(values: T...) -> Int {
    return values.length();
}

class Joiner {
    func join(parts: String..., sep: String = "/") -> String {
        return join_parts(parts..., sep=sep);
    }
}

func main() -> Int {
    let words: Vector(String) = ["a", "b", "c"];
    let suffix: String[2] = ["d", "e"];
    let saved: Array(String) = collect("saved", "pack");
    let joiner = Joiner();

    if (join_parts("x", words..., suffix..., "z", sep=":") != "x:a:b:c:d:e:z" ||
        joiner.join("m", "n") != "m/n" || saved[1] != "pack" ||
        count(1, 2, 3) != 3 || count(words...) != 3) {
        print("FAIL: Native variadic arguments");
        return 1;
    }

    print("PASS: Native variadic arguments");
    return 0;
}
