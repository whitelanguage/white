// Test: NAMED_UNARY
// File: tests/language/types/test_named_unary.wl
// Focus: Named numeric and Bool types preserve their identity in unary expressions.

type Count = Int;
type Real = Float;
type Small = Float32;
type Flag = Bool;

func main() -> Int {
    let count = Count(3);
    let negative: Count = -count;
    let positive: Count = +count;
    let inverted: Count = ~count;
    let real = Real(1.5);
    let old_real: Real = real++;
    let negative_real: Real = -real;
    let small = Small(2.5f);
    let old_small: Small = small--;
    let flag = Flag(true);
    let opposite: Flag = !flag;
    let conjunction: Flag = flag && opposite;
    let disjunction = flag || opposite;

    if (negative != Count(-3) || positive != count || inverted != Count(-4) ||
        old_real != Real(1.5) || real != Real(2.5) || negative_real != Real(-2.5) ||
        old_small != Small(2.5f) || small != Small(1.5f) || opposite != Flag(false) ||
        conjunction != Flag(false) || disjunction != flag) {
        print("FAIL: named unary operations");
        return 1;
    }

    print("PASS: named unary operations");
    return 0;
}
