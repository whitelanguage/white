// Test: ALIAS_ARITY
// File: tests/diagnostics/failures/test_alias_arity.wl
// Focus: Generic type aliases check their type argument count.
// Expected Error: "TypeError: Type 'Identity' expects 1 type arguments, got 2."

type T as Identity<T>;

func main() -> Int {
    let value: Identity(Int, String) = 0;
    return 0;
}
