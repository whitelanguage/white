// Test: OPTIONAL_WRITE
// File: tests/diagnostics/failures/test_optional_write.wl
// Focus: Replacing an enclosing union cannot leave a writable address to its old arm.
// Expected Error: "TypeError: Optional field assignment loses its null check while evaluating the assigned value."

struct Pair(text: String)

func reset(ref value: Optional(Pair)) -> String {
    value = null;
    return "changed";
}

func main() -> Int {
    let pair: Optional(Pair) = Pair("original");
    if (pair is null) { return 0; }
    pair.text = reset(ref pair);
    return 0;
}
