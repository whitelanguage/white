// Test: UNION_MEMBER
// File: tests/diagnostics/failures/test_union_member.wl
// Focus: A union does not implicitly convert a value to one of its members.
// Expected Error: "TypeError: Type mismatch. Expected (Null | Int), got UInt32."

func main() -> Int {
    let value: Optional(Int) = 1U;
    return 0;
}
