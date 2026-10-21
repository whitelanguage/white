// Test: UNION_PRINT
// File: tests/diagnostics/failures/test_union_print.wl
// Focus: Reporting unsupported union printing without exposing a lowering error.
// Expected Error: "TypeError: Type (Null | Int) cannot be printed."

func main() -> Int {
    let value: Optional(Int) = 1;
    print(value);
    return 0;
}
