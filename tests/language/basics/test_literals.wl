// Test: LITERAL_EXPRESSIONS
// File: tests/language/basics/test_literals.wl
// Focus: Handling of negative floats, multiple unary operators, and boolean logic.


func main() -> Int {
    // multiple unary minus on floats
    let complex_float: Float = 0.1 + -(-0.2); // Equivalent to 0.1 + 0.2
    
    // comparison operators
    let bool_test: Bool = (5 >= 3) && true;

    if (complex_float > 0.299999 && complex_float < 0.300001 && bool_test) {
        print("PASS: Literals and unary operators");
    } else {
        print("FAIL: Unary fusion or boolean literal error");
    }
    return 0;

}