// Test: UNION_LOGIC
// File: tests/diagnostics/failures/test_union_logic.wl
// Focus: Logical operators cannot read an unchecked Optional Bool as Bool.
// Expected Error: "TypeError: Logic operators '&&' and '||' require Bool operands."

func main() -> Int {
    let value: Optional(Bool) = true;
    let result = value && true;
    return 0;
}
