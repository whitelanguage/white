// Test: UNION_VOID
// File: tests/diagnostics/failures/test_union_void.wl
// Focus: Void is a function result, not a union member representing absence.
// Expected Error: "TypeError: Union members must be value types, got Void."

type (String | Void) as Invalid;

func main() -> Int {
    return 0;
}
