// Test: ENUM_DECLARATION_AND_USAGE
// File: tests/language/types/test_enum.wl
// Focus: Strong-typed scoped enum declaration, explicit value assignment, and equality checks.


enum Color {
    RED,
    GREEN,
    BLUE = 10,
    YELLOW
}

func main() -> Int {
    let c1: Color = Color.RED;
    let c2: Color = Color.BLUE;
    let c3: Enum = Color.BLUE;
    let c4: Auto  = Color.YELLOW;

    let res: Bool = true;

    if (c1 == Color.GREEN) { res = false; }
    if (c1 == Color.RED) {} else { res = false; }
    
    if (c2 != c3) { res = false; }
    if (c2 == c1) { res = false; }

    if res {
        print("PASS: Enum assignment and equality check working");
        return 0;
    } else {
        print("FAIL: Enum value mismatch");
        return 1;
    }
}
