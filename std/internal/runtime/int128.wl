// std/internal/runtime/int128.wl
// software division hooks for targets without native 128-bit division

func uint128_div_rem(dividend: UInt128, divisor: UInt128, ptr remainder_out: UInt128) -> UInt128 {
// perform binary long division without compiler-rt helpers
    if (divisor == UInt128(0)) {
        if (remainder_out is !nullptr) { deref remainder_out = UInt128(0); }
        return UInt128(0);
    }
    if (dividend < divisor) {
        if (remainder_out is !nullptr) { deref remainder_out = dividend; }
        return UInt128(0);
    }
    if (divisor == UInt128(1)) {
        if (remainder_out is !nullptr) { deref remainder_out = UInt128(0); }
        return dividend;
    }

    let quotient: UInt128 = UInt128(0);
    let remainder: UInt128 = UInt128(0);
    let bit: Int = 127;
    while (bit >= 0) {
        let overflow: Bool = (remainder >> UInt128(127)) != UInt128(0);
        remainder = (remainder << UInt128(1)) | ((dividend >> UInt128(bit)) & UInt128(1));
        if (overflow || remainder >= divisor) {
            remainder -= divisor;
            quotient |= UInt128(1) << UInt128(bit);
        }
        bit -= 1;
    }

    if (remainder_out is !nullptr) { deref remainder_out = remainder; }
    return quotient;
}

@CompilerLink("uint128_div")
func uint128_div(dividend: UInt128, divisor: UInt128) -> UInt128 {
    let remainder: UInt128 = UInt128(0);
    return uint128_div_rem(dividend, divisor, ref remainder);
}

@CompilerLink("uint128_rem")
func uint128_rem(dividend: UInt128, divisor: UInt128) -> UInt128 {
    let remainder: UInt128 = UInt128(0);
    uint128_div_rem(dividend, divisor, ref remainder);
    return remainder;
}

@CompilerLink("int128_div")
func int128_div(dividend: Int128, divisor: Int128) -> Int128 {
    let dividend_negative: Bool = dividend < Int128(0);
    let divisor_negative: Bool = divisor < Int128(0);
    let dividend_magnitude: UInt128 = UInt128(dividend);
    let divisor_magnitude: UInt128 = UInt128(divisor);
    if dividend_negative { dividend_magnitude = UInt128(0) - dividend_magnitude; }
    if divisor_negative { divisor_magnitude = UInt128(0) - divisor_magnitude; }

    let quotient: UInt128 = uint128_div(dividend_magnitude, divisor_magnitude);
    if (dividend_negative != divisor_negative) { return Int128(UInt128(0) - quotient); }
    return Int128(quotient);
}

@CompilerLink("int128_rem")
func int128_rem(dividend: Int128, divisor: Int128) -> Int128 {
    let dividend_negative: Bool = dividend < Int128(0);
    let dividend_magnitude: UInt128 = UInt128(dividend);
    let divisor_magnitude: UInt128 = UInt128(divisor);
    if dividend_negative { dividend_magnitude = UInt128(0) - dividend_magnitude; }
    if (divisor < Int128(0)) { divisor_magnitude = UInt128(0) - divisor_magnitude; }

    let remainder: UInt128 = uint128_rem(dividend_magnitude, divisor_magnitude);
    if dividend_negative { return Int128(UInt128(0) - remainder); }
    return Int128(remainder);
}
