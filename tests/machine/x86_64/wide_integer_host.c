// Test: X86_64_WIDE_INTEGER_HOST
// File: tests/machine/x86_64/wide_integer_host.c
// Focus: Check the Windows x64 __int128 ABI and integer operation results.

typedef unsigned __int128 u128;
typedef __int128 i128;

extern u128 native_add128(u128, u128);
extern u128 native_sub128(u128, u128);
extern u128 native_mul128(u128, u128);
extern u128 native_and128(u128, u128);
extern u128 native_or128(u128, u128);
extern u128 native_xor128(u128, u128);
extern i128 native_neg128(i128);
extern u128 native_not128(u128);
extern u128 native_shl128(u128, u128);
extern u128 native_lshr128(u128, u128);
extern i128 native_ashr128(i128, i128);
extern u128 native_udiv128(u128, u128);
extern u128 native_urem128(u128, u128);
extern i128 native_sdiv128(i128, i128);
extern i128 native_srem128(i128, i128);
extern _Bool native_eq128(u128, u128);
extern _Bool native_ne128(u128, u128);
extern _Bool native_ult128(u128, u128);
extern _Bool native_ule128(u128, u128);
extern _Bool native_ugt128(u128, u128);
extern _Bool native_uge128(u128, u128);
extern _Bool native_slt128(i128, i128);
extern _Bool native_sle128(i128, i128);
extern _Bool native_sgt128(i128, i128);
extern _Bool native_sge128(i128, i128);
extern _Bool native_extend_uge128(int, int);
extern u128 native_relay128(u128, u128);
extern u128 native_constant128(void);
extern u128 native_memory128(u128);
extern u128 native_field128(u128);
extern u128 native_select128(_Bool, u128, u128);

u128 host_add128(u128 left, u128 right) {
    return left + right;
}

static u128 reference_udiv128(u128 dividend, u128 divisor, u128* remainder) {
    u128 quotient = 0;
    u128 current = 0;
    for (int bit = 0; bit < 128; ++bit) {
        current = (current << 1) | (dividend >> 127);
        dividend <<= 1;
        quotient <<= 1;
        if (current >= divisor) {
            current -= divisor;
            quotient |= 1;
        }
    }
    *remainder = current;
    return quotient;
}

static u128 magnitude128(i128 value) {
    u128 bits = (u128)value;
    if (value < 0) bits = (u128)0 - bits;
    return bits;
}

#if defined(TEST_UNSIGNED_DIVIDE_BY_ZERO)
int host_verify128(void) {
    volatile u128 zero = 0;
    (void)native_udiv128(1, zero);
    return 1;
}
#elif defined(TEST_SIGNED_DIVIDE_OVERFLOW)
int host_verify128(void) {
    const i128 minimum = (i128)((u128)1 << 127);
    (void)native_sdiv128(minimum, -1);
    return 1;
}
#else
int host_verify128(void) {
    const u128 mask = ((u128)0xfedcba9876543210ULL << 64) | 0x0123456789abcdefULL;
    if (native_extend_uge128(9, 10) || !native_extend_uge128(10, 10) || !native_extend_uge128(11, 10)) return 25;
    u128 left = ((u128)0x123456789abcdef0ULL << 64) | 0xfedcba9876543210ULL;
    u128 right = ((u128)0x0f1e2d3c4b5a6978ULL << 64) | 0x8877665544332211ULL;
    for (int i = 0; i < 1024; ++i) {
        if (right == 0) right = 1;
        if (native_add128(left, right) != left + right) return 1;
        if (native_sub128(left, right) != left - right) return 2;
        if (native_mul128(left, right) != left * right) return 3;
        if (native_and128(left, right) != (left & right)) return 4;
        if (native_or128(left, right) != (left | right)) return 5;
        if (native_xor128(left, right) != (left ^ right)) return 6;
        if (native_relay128(left, right) != ((left + right) ^ mask)) return 7;
        if (native_memory128(left) != left) return 8;
        if (native_field128(right) != right) return 9;
        if (native_select128(1, left, right) != left || native_select128(0, left, right) != right) return 10;
        if ((u128)native_neg128((i128)left) != (u128)(-(i128)left)) return 11;
        if (native_not128(left) != ~left) return 12;
        const unsigned shift = (unsigned)i & 127U;
        if (native_shl128(left, (u128)shift) != left << shift) return 13;
        if (native_lshr128(left, (u128)shift) != left >> shift) return 14;
        if (native_ashr128((i128)left, (i128)shift) != (i128)left >> shift) return 15;
        if (native_eq128(left, right) != (left == right) || native_ne128(left, right) != (left != right)) return 16;
        if (native_ult128(left, right) != (left < right) || native_ule128(left, right) != (left <= right)) return 17;
        if (native_ugt128(left, right) != (left > right) || native_uge128(left, right) != (left >= right)) return 18;
        if (native_slt128((i128)left, (i128)right) != ((i128)left < (i128)right) || native_sle128((i128)left, (i128)right) != ((i128)left <= (i128)right)) return 19;
        if (native_sgt128((i128)left, (i128)right) != ((i128)left > (i128)right) || native_sge128((i128)left, (i128)right) != ((i128)left >= (i128)right)) return 20;
        u128 unsigned_remainder = 0;
        const u128 unsigned_quotient = reference_udiv128(left, right, &unsigned_remainder);
        if (native_udiv128(left, right) != unsigned_quotient || native_urem128(left, right) != unsigned_remainder) return 21;
        const i128 signed_left = (i128)left;
        const i128 signed_right = (i128)right;
        u128 signed_remainder = 0;
        u128 signed_quotient = reference_udiv128(magnitude128(signed_left), magnitude128(signed_right), &signed_remainder);
        if ((signed_left < 0) != (signed_right < 0)) signed_quotient = (u128)0 - signed_quotient;
        if (signed_left < 0) signed_remainder = (u128)0 - signed_remainder;
        if ((u128)native_sdiv128(signed_left, signed_right) != signed_quotient || (u128)native_srem128(signed_left, signed_right) != signed_remainder) return 22;
        left ^= left << 29;
        left ^= left >> 17;
        left ^= left << 43;
        right += ((u128)0x9e3779b97f4a7c15ULL << 64) | 0xd1b54a32d192ed03ULL;
    }
    if (native_constant128() != mask) return 23;
    const u128 wide = ((u128)0xfedcba9876543210ULL << 64) | 0x89abcdef01234567ULL;
    const unsigned long long small_divisors[] = {1ULL, 3ULL, 0xffffffffffffffffULL};
    for (int i = 0; i < 3; ++i) {
        const u128 divisor = (u128)small_divisors[i];
        u128 expected_remainder = 0;
        const u128 expected_quotient = reference_udiv128(wide, divisor, &expected_remainder);
        if (native_udiv128(wide, divisor) != expected_quotient || native_urem128(wide, divisor) != expected_remainder) return 24;
    }
    return 0;
}
#endif
