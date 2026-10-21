// Test: ALIAS_CYCLE
// File: tests/diagnostics/failures/test_alias_cycle.wl
// Focus: Recursive generic aliases report an error before exhausting the native stack.
// Expected Error: "TypeError: Type alias 'Loop' is recursive."

type Loop(T) as Loop<T>;
type Loop(Int) as Invalid;

func main() -> Int {
    return 0;
}
