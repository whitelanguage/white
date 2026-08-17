// Test: NATIVE_VARIADIC
// File: tests/language/control/test_variadic.wl
// Focus: Native variadic packs, defaults, expansion, callable values, generics, methods, and escaped storage.

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

func surround(prefix: String, values: String..., suffix: String) -> String {
    return prefix + join_parts(values..., sep=",") + suffix;
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
    let inferred = join_parts;
    let renamed: Function(String..., delimiter: String) -> String = join_parts;
    let inferred_method = joiner.join;
    let renamed_method: Method(String..., delimiter: String) -> String = joiner.join;
    let inferred_surround = surround;
    let renamed_surround: Function(String, String..., end: String) -> String = surround;
    let erased: Function = renamed;
    let restored: Function(String..., separator: String) -> String = erased;
    let erased_method: Method = renamed_method;
    let restored_method: Method(String..., separator: String) -> String = erased_method;

    if (join_parts("x", words..., suffix..., "z", sep=":") != "x:a:b:c:d:e:z" ||
        joiner.join("m", "n") != "m/n" || saved[1] != "pack" ||
        count(1, 2, 3) != 3 || count(words...) != 3 ||
        inferred("f", "g", sep="+") != "f+g" ||
        renamed("h", "i", delimiter="|") != "h|i" ||
        inferred_method("j", "k", sep=".") != "j.k" ||
        renamed_method("l", "m", delimiter="_") != "l_m" ||
        inferred_surround("[", "n", "o", suffix="]") != "[n,o]" ||
        renamed_surround("<", "p", "q", end=">") != "<p,q>" ||
        restored("r", "s", separator="~") != "r~s" ||
        restored_method("t", "u", separator="^") != "t^u") {
        print("FAIL: Native variadic arguments");
        return 1;
    }

    print("PASS: Native variadic arguments");
    return 0;
}
