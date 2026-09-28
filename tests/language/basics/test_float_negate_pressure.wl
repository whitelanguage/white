// Test: FLOAT_NEGATE_REGISTER_PRESSURE
// File: tests/language/basics/test_float_negate_pressure.wl
// Focus: Preserving live floating-point values while lowering f64 negation in loops.

const PI: Float = 3.141592653589793;
const TAU: Float = 6.283185307179586;

func wrap_angle(value: Float) -> Float {
    let result: Float = value;
    while (result > PI) { result -= TAU; }
    while (result < -PI) { result += TAU; }
    return result;
}

func main() -> Int {
    let positive: Float = wrap_angle(4.0);
    let negative: Float = wrap_angle(-4.0);
    if (positive < -2.29 || positive > -2.28 || negative < 2.28 || negative > 2.29) {
        print("FAIL: Float negate corrupted a live loop value");
        return 1;
    }
    print("PASS: Float negate register pressure");
    return 0;
}
