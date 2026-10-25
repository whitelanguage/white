// tests/fixtures/modules/inference.wl
enum Choice { First, Second }

class Reader {
    func value() -> Int { return 42; }
}

struct Pair(first: Int, second: Int = 2)
