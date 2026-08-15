// Test: GENERIC_ARITY
// File: tests/diagnostics/failures/test_generic_arity.wl
// Focus: Rejecting a generic type with the wrong number of type arguments.
// Expected Error: "TypeError: Type 'Pair' expects 2 type arguments, got 1."

struct Pair<T, K>(first: T, second: K)

func main() -> Int {
    let pair: Pair(Int) = null;
    return 0;
}
