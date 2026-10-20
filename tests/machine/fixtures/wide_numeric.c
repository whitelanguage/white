// Test: WIDE_NUMERIC_HOST
// File: tests/machine/fixtures/wide_numeric.c
// Focus: Compare native wide conversions with an independent C compiler, including rounding ties.

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <math.h>

typedef unsigned __int128 u128;
typedef __int128 i128;
extern float signed_to_32(i128);
extern double signed_to_64(i128);
extern float unsigned_to_32(u128);
extern double unsigned_to_64(u128);
extern i128 to_signed_32(float);
extern i128 to_signed_64(double);
extern u128 to_unsigned_32(float);
extern u128 to_unsigned_64(double);
extern i128 absolute128(i128);

static uint64_t state = UINT64_C(0x734afb901237568d);
static uint64_t random_word(void) {
    state ^= state << 13;
    state ^= state >> 7;
    state ^= state << 17;
    return state;
}
static uint32_t float_bits(float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof bits);
    return bits;
}
static uint64_t double_bits(double value) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof bits);
    return bits;
}
static int check_integer(u128 value) {
    i128 signed_value = (i128)value;
    if (float_bits(unsigned_to_32(value)) != float_bits((float)value) ||
        double_bits(unsigned_to_64(value)) != double_bits((double)value) ||
        float_bits(signed_to_32(signed_value)) != float_bits((float)signed_value) ||
        double_bits(signed_to_64(signed_value)) != double_bits((double)signed_value)) {
        printf("FAIL: integer rounding, %016llx:%016llx\n",
               (unsigned long long)(value >> 64), (unsigned long long)value);
        return 0;
    }
    u128 magnitude = value >> 127 ? (u128)0 - value : value;
    if ((u128)absolute128(signed_value) != magnitude) {
        puts("FAIL: signed 128-bit absolute value");
        return 0;
    }
    return 1;
}
static int check_float(double value) {
    float single = (float)value;
    if (isfinite(value) && value >= -0x1p127 && value < 0x1p127 &&
        to_signed_64(value) != (i128)value) { puts("FAIL: f64 to i128"); return 0; }
    if (isfinite(value) && value >= 0 && value < 0x1p128 &&
        to_unsigned_64(value) != (u128)value) { puts("FAIL: f64 to u128"); return 0; }
    if (isfinite(single) && single >= -0x1p127f && single < 0x1p127f &&
        to_signed_32(single) != (i128)single) { puts("FAIL: f32 to i128"); return 0; }
    if (isfinite(single) && single >= 0 && single < 0x1p128 &&
        to_unsigned_32(single) != (u128)single) { puts("FAIL: f32 to u128"); return 0; }
    return 1;
}
int main(void) {
    if (!check_integer(0) || !check_integer(1) || !check_integer(~(u128)0) ||
        !check_integer((u128)1 << 127)) { return 1; }
    // walk every exponent, then both sides of a tie and of a significand carry
    for (int bit = 1; bit < 128; bit++) {
        u128 base = (u128)1 << bit;
        if (!check_integer(base) || !check_integer(base - 1) ||
            !check_integer(base + 1) || !check_integer((u128)0 - base)) { return 1; }
        for (int precision = 24; precision <= 53; precision += 29) {
            if (bit < precision) { continue; }
            u128 half = (u128)1 << (bit - precision);
            u128 spacing = half << 1;
            for (int odd = 0; odd < 2; odd++) {
                u128 tie = base + odd * spacing + half;
                if (!check_integer(tie - 1) || !check_integer(tie) ||
                    !check_integer(tie + 1) || !check_integer((u128)0 - tie)) { return 1; }
            }
        }
    }
    double edges[] = {0.0, -0.0, 0.5, -0.5, 1.75, -1.75, 0x1p52, 0x1p64,
        0x1p100, -0x1p127, 0x1.fffffffffffffp126, 0x1.fffffffffffffp127,
        0x1p-1022, 0x1p-1074};
    for (unsigned i = 0; i < sizeof edges / sizeof edges[0]; i++) {
        if (!check_float(edges[i])) { return 1; }
    }
    for (int i = 0; i < 20000; i++) {
        u128 value = ((u128)random_word() << 64) | random_word();
        if (!check_integer(value)) { return 1; }
        uint64_t bits = random_word();
        double number;
        memcpy(&number, &bits, sizeof number);
        if (!check_float(number)) { return 1; }
    }
    puts("PASS: wide numeric casts match C and IEEE tie rounding");
    return 0;
}
