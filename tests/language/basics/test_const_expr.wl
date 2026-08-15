// Test: GLOBAL_CONSTANT_EXPRESSIONS
// File: tests/language/basics/test_const_expr.wl
// Focus: Folding numeric global constants without losing floating-point precision.


const PI: Float = 3.14159265358979323846;
const HALF_PI: Float = PI / 2;
const SCALE: Int = 2;
const OFFSET: Int = SCALE + 3;
const WIDE_BASE: Int128 = 170141183460469231731687303715884105720LL;
const WIDE_NEXT: Int128 = WIDE_BASE + 1;
const ENABLED: Bool = true;
const ENABLED_COPY: Bool = ENABLED;
const RESTORED_PI: Float = HALF_PI * SCALE;
const POWER: Float = 2.0 ** 10.0;
const REMAINDER: Float = 5.5 % 2.0;
const THIRD: Float32 = 1.0 / 3.0;

func close(left: Float, right: Float, tolerance: Float) -> Bool {
    let difference: Float = left - right;
    if (difference < 0.0) { difference = 0.0 - difference; }
    return difference <= tolerance;
}

func main() -> Int {
    if (!close(HALF_PI, 1.5707963267948966, 0.000000000000001) || !close(RESTORED_PI, PI, 0.000000000000001) || POWER != 1024.0 || REMAINDER != 1.5 || !close(Float(THIRD), 0.3333333432674408, 0.000000000000001) || OFFSET != 5 || WIDE_NEXT != 170141183460469231731687303715884105721LL || !ENABLED_COPY) {
        print("FAIL: global constant expressions");
        return 1;
    }
    print("PASS: global constant expressions");
    return 0;
}
