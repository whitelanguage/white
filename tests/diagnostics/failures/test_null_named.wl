// Test: NULL_NAMED_RETURN
// File: tests/diagnostics/failures/test_null_named.wl
// Focus: A distinct integer type retains its non-nullable representation.
// Expected Error: "TypeError: Type Count cannot be null."

type Count = Int;

func value() -> Count {
    return null;
}

func main() -> Int {
    let count: Count = value();
    return Int(count);
}
