// Test: RECURSIVE_NAMED_TYPE
// File: tests/diagnostics/failures/test_type_cycle.wl
// Focus: Rejecting named types with recursive value representations.
// Expected Error: "TypeError: Type declaration for 'First' is recursive."

type First = Second;
type Second = First;

func main() -> Int { return 0; }
