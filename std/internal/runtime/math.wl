// std/internal/runtime/math.wl
// floating-point hooks used by compiler-generated arithmetic

const __FLOAT_SIGN: UInt64 = 9223372036854775808UL;
const __FLOAT_ABS: UInt64 = 9223372036854775807UL;
const __FLOAT_EXP: UInt64 = 9218868437227405312UL;
const __FLOAT_FRAC: UInt64 = 4503599627370495UL;
const __FLOAT_ONE: UInt64 = 4607182418800017408UL;
const __FLOAT_INF: UInt64 = 9218868437227405312UL;
const __FLOAT_NAN: UInt64 = 9221120237041090560UL;
const __FLOAT_HIGH: UInt64 = 18446744069414584320UL;

func __float_bits(value: Float) -> UInt64 {
    let raw: AnyPtr = AnyPtr(ref value);
    let ptr bits: UInt64 = raw;
    return deref bits;
}

func __float_from_bits(bits: UInt64) -> Float {
    let raw: AnyPtr = AnyPtr(ref bits);
    let ptr value: Float = raw;
    return deref value;
}

func __float_abs(value: Float) -> Float {
    return __float_from_bits(__float_bits(value) & __FLOAT_ABS);
}

func __float_high(value: Float) -> Float {
    return __float_from_bits(__float_bits(value) & __FLOAT_HIGH);
}

func __float_integer_kind(value: Float) -> Int {
    // 0 is fractional, 1 is even, and 2 is odd
    let bits: UInt64 = __float_bits(__float_abs(value));
    let exponent: Int = Int((bits >> UInt64(52)) & UInt64(2047));
    if (exponent < 1023) { return 0; }
    let width: Int = exponent - 1023;
    if (width > 52) { return 1; }
    let shift: Int = 52 - width;
    let mask: UInt64 = (UInt64(1) << UInt64(shift)) - UInt64(1);
    if ((bits & mask) != UInt64(0)) { return 0; }
    if (((bits >> UInt64(shift)) & UInt64(1)) != UInt64(0)) { return 2; }
    return 1;
}

@CompilerLink("float_mod")
func float_mod(left: Float, right: Float) -> Float {
    // reduce the significands directly so code generation never needs a libc fmod
    let left_bits: UInt64 = __float_bits(left);
    let right_bits: UInt64 = __float_bits(right);
    let sign: UInt64 = left_bits & __FLOAT_SIGN;
    let left_abs: UInt64 = left_bits & __FLOAT_ABS;
    let right_abs: UInt64 = right_bits & __FLOAT_ABS;
    if (right_abs == UInt64(0) || left_abs >= __FLOAT_EXP || right_abs > __FLOAT_EXP) { return __float_from_bits(__FLOAT_NAN); }
    if (left_abs < right_abs) { return left; }
    if (left_abs == right_abs) { return __float_from_bits(sign); }

    let left_exp_bits: Int = Int((left_abs >> UInt64(52)) & UInt64(2047));
    let right_exp_bits: Int = Int((right_abs >> UInt64(52)) & UInt64(2047));
    let left_exp: Int = -1022;
    let right_exp: Int = -1022;
    let left_mantissa: UInt64 = left_abs & __FLOAT_FRAC;
    let right_mantissa: UInt64 = right_abs & __FLOAT_FRAC;
    if (left_exp_bits != 0) { left_exp = left_exp_bits - 1023; left_mantissa |= UInt64(1) << UInt64(52); }
    else { while (left_mantissa < (UInt64(1) << UInt64(52))) { left_mantissa <<= UInt64(1); left_exp -= 1; } }
    if (right_exp_bits != 0) { right_exp = right_exp_bits - 1023; right_mantissa |= UInt64(1) << UInt64(52); }
    else { while (right_mantissa < (UInt64(1) << UInt64(52))) { right_mantissa <<= UInt64(1); right_exp -= 1; } }

    while (left_exp > right_exp) {
        if (left_mantissa >= right_mantissa) { left_mantissa -= right_mantissa; }
        left_mantissa <<= UInt64(1);
        left_exp -= 1;
    }
    if (left_mantissa >= right_mantissa) { left_mantissa -= right_mantissa; }
    if (left_mantissa == UInt64(0)) { return __float_from_bits(sign); }
    while (left_mantissa < (UInt64(1) << UInt64(52))) { left_mantissa <<= UInt64(1); left_exp -= 1; }

    let result_bits: UInt64 = sign;
    if (left_exp >= -1022) {
        result_bits |= UInt64(left_exp + 1023) << UInt64(52);
        result_bits |= left_mantissa & __FLOAT_FRAC;
    } else {
        result_bits |= left_mantissa >> UInt64(-1022 - left_exp);
    }
    return __float_from_bits(result_bits);
}

func __float_log(value: Float, ptr low_out: Float) -> Float {
    let bits: UInt64 = __float_bits(value);
    let exponent_bits: Int = Int((bits >> UInt64(52)) & UInt64(2047));
    let exponent: Int = exponent_bits - 1023;
    if (exponent_bits == 0) {
        value *= 4503599627370496.0;
        bits = __float_bits(value);
        exponent_bits = Int((bits >> UInt64(52)) & UInt64(2047));
        exponent = exponent_bits - 1075;
    }

    let mantissa_bits: UInt64 = (bits & __FLOAT_FRAC) | __FLOAT_ONE;
    let mantissa: Float = __float_from_bits(mantissa_bits);
    if (mantissa > 1.4142135623730951) {
        mantissa *= 0.5;
        exponent += 1;
    }

    let z: Float = (mantissa - 1.0) / (mantissa + 1.0);
    let square: Float = z * z;
    let term: Float = z;
    let sum: Float = z;
    let divisor: Int = 3;
    while (divisor <= 31) {
        term *= square;
        sum += term / Float(divisor);
        divisor += 2;
    }
    let mantissa_log: Float = 2.0 * sum;
    let exponent_high: Float = Float(exponent) * 0.693147182464599609375;
    let exponent_low: Float = Float(exponent) * -0.000000001904654299957768;
    let combined: Float = exponent_high + (mantissa_log + exponent_low);
    let high: Float = __float_high(combined);
    deref low_out = (exponent_high - high) + mantissa_log + exponent_low;
    return high;
}

func __float_exp_product(exponent_value: Float, logarithm_high: Float, logarithm_low: Float) -> Float {
    let exponent_high: Float = __float_high(exponent_value);
    let product_high: Float = exponent_high * logarithm_high;
    let product_low: Float = (exponent_value - exponent_high) * logarithm_high + exponent_value * logarithm_low;
    let product: Float = product_high + product_low;
    if (product > 709.782712893384) { return __float_from_bits(__FLOAT_INF); }
    if (product < -745.1332191019411) { return 0.0; }

    let binary_exponent: Long = Long(product * 1.4426950408889634);
    let reduced_probe: Float = product - Float(binary_exponent) * 0.6931471805599453;
    if (reduced_probe > 0.34657359027997265) {
        binary_exponent += 1L;
    } else if (reduced_probe < -0.34657359027997265) {
        binary_exponent -= 1L;
    }

    let reduced: Float = (product_high - Float(binary_exponent) * 0.693147182464599609375) + (product_low - Float(binary_exponent) * -0.000000001904654299957768);
    let sum: Float = 1.0;
    let term: Float = 1.0;
    let i: Int = 1;
    while (i <= 16) {
        term *= reduced / Float(i);
        sum += term;
        i += 1;
    }

    if (binary_exponent > 1023L) {
        let high: Float = __float_from_bits(UInt64(2046) << UInt64(52));
        return (sum * high) * 2.0;
    }
    if (binary_exponent >= -1022L) {
        let scale_bits: UInt64 = UInt64(binary_exponent + 1023L) << UInt64(52);
        return sum * __float_from_bits(scale_bits);
    }

    let minimum_normal: Float = __float_from_bits(UInt64(1) << UInt64(52));
    let tail_bits: UInt64 = UInt64(binary_exponent + 2045L) << UInt64(52);
    return (sum * __float_from_bits(tail_bits)) * minimum_normal;
}

@CompilerLink("float_pow")
func float_pow(base: Float, exponent: Float) -> Float {
    let base_bits: UInt64 = __float_bits(base);
    let exponent_bits: UInt64 = __float_bits(exponent);
    let base_abs_bits: UInt64 = base_bits & __FLOAT_ABS;
    let exponent_abs_bits: UInt64 = exponent_bits & __FLOAT_ABS;

    if (exponent_abs_bits == UInt64(0)) { return 1.0; }
    if (base_bits == __FLOAT_ONE) { return 1.0; }
    if (exponent_abs_bits > __FLOAT_EXP) { return exponent; }
    if (base_abs_bits > __FLOAT_EXP) { return base; }

    let base_abs: Float = __float_from_bits(base_abs_bits);
    let exponent_negative: Bool = (exponent_bits & __FLOAT_SIGN) != UInt64(0);
    let base_negative: Bool = (base_bits & __FLOAT_SIGN) != UInt64(0);
    if (exponent_abs_bits == __FLOAT_EXP) {
        if (base_abs == 1.0) { return 1.0; }
        if ((base_abs > 1.0) != exponent_negative) { return __float_from_bits(__FLOAT_INF); }
        return 0.0;
    }

    let integer_kind: Int = __float_integer_kind(exponent);
    let negative_result: Bool = base_negative && integer_kind == 2;
    if (base_abs_bits == __FLOAT_EXP || base_abs_bits == UInt64(0)) {
        let result: Float = 0.0;
        if ((base_abs_bits == __FLOAT_EXP) != exponent_negative) { result = __float_from_bits(__FLOAT_INF); }
        if negative_result { return -result; }
        return result;
    }
    if (base_negative && integer_kind == 0) { return __float_from_bits(__FLOAT_NAN); }

    let logarithm_low: Float = 0.0;
    let logarithm_high: Float = __float_log(base_abs, ref logarithm_low);
    let result: Float = __float_exp_product(exponent, logarithm_high, logarithm_low);
    if negative_result { return -result; }
    return result;
}
