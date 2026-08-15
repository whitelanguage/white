// Test: ARITHMETIC_VAR
// File: tests/language/basics/test_var_arithmetic.wl
// Focus: Implicit type promotion (Int to Float) and complex expression precedence.


func main() -> Int {
    let a: Int = 5;
    let b: Float = 3.2;

    // type promotion in binary ops (Int + Float: Float)
    let res: Float = a + b;
    
    // operator precedence and unary fusion
    // ((a*a)/b) + (b/a) - b - (+b)
    let complex_calc: Float = a * a / b + b / a - b -+ b;

    if (complex_calc != 0.0) {
        print("PASS: Arithmetic integrity");
    } else {
        print("FAIL: Arithmetic mismatch");
    }

    return 0;
}
