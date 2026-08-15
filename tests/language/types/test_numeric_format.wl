// Test: LIBC_FREE_NUMERIC_FORMAT
// File: tests/language/types/test_numeric_format.wl
// Focus: Signed integer limit string conversion and six-digit float rounding independent of libc.


func main() -> Int {
    let int_min: Int = -2147483647 - 1;
    let long_min: Long = -9223372036854775807L - 1L;

    let int_ok: Bool = "" + int_min == "-2147483648";
    let long_ok: Bool = "" + long_min == "-9223372036854775808";
    let zero_ok: Bool = "" + 0 == "0";
    let round_ok: Bool = "" + 3.14159 == "3.141590";
    let carry_ok: Bool = "" + 1.9999996 == "2.000000";
    let negative_ok: Bool = "" + -0.125 == "-0.125000";
    let int128_min: Int128 = -170141183460469231731687303715884105727LL - Int128(1);
    let uint128_max: UInt128 = 340282366920938463463374607431768211455ULL;
    let int128_ok: Bool = "" + int128_min == "-170141183460469231731687303715884105728";
    let uint128_ok: Bool = "" + uint128_max == "340282366920938463463374607431768211455";
    let uint128_zero_ok: Bool = "" + UInt128(0) == "0";
    let uint128_chunk_ok: Bool = "" + 1000000000ULL == "1000000000";
    let uint128_limb_ok: Bool = "" + 18446744073709551616ULL == "18446744073709551616";
    let int128_mid_ok: Bool = "" + -123456789012345678901234567890LL == "-123456789012345678901234567890";

    if (!int_ok || !long_ok || !zero_ok || !round_ok || !carry_ok || !negative_ok ||
        !int128_ok || !uint128_ok || !uint128_zero_ok || !uint128_chunk_ok ||
        !uint128_limb_ok || !int128_mid_ok) {
        print("FAIL: libc-free numeric formatting");
        return 1;
    }

    print("PASS: libc-free numeric formatting");
    return 0;
}
