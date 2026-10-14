// Test: AARCH64_AAPCS64_C_ABI_HOST
// File: tests/machine/aarch64/fixtures/aapcs64_abi_host.c
// Focus: Call White functions through the system AArch64 C ABI and receive callbacks from White.

#include <stdint.h>
#include <stdio.h>

struct Pair { int64_t x; int32_t y; };
struct Hfa { double a, b, c; };
struct Large { int64_t a, b, c; };

extern struct Pair pair_make(int64_t x, int32_t y);
extern int64_t pair_sum(struct Pair value);
extern struct Hfa hfa_make(double a, double b, double c);
extern double hfa_sum(struct Hfa value);
extern struct Hfa hfa_relay(struct Hfa value);
extern struct Large large_make(int64_t a, int64_t b, int64_t c);
extern int64_t large_sum(struct Large value);
extern struct Large large_relay(struct Large value);
extern unsigned __int128 wide_add(unsigned __int128 value, unsigned __int128 extra);
extern unsigned __int128 wide_relay(unsigned __int128 value);
extern int64_t stack_pair(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, struct Pair);

struct Hfa host_hfa(struct Hfa value) {
    value.a += 1.0;
    value.b += 2.0;
    value.c += 3.0;
    return value;
}

struct Large host_large(struct Large value) {
    value.a += 1;
    value.b += 2;
    value.c += 3;
    return value;
}

unsigned __int128 host_wide(unsigned __int128 value) {
    return value + (((unsigned __int128)1) << 96) + 9;
}

int main(void) {
    struct Pair pair = pair_make(10, 32);
    if (pair.x != 10 || pair.y != 32 || pair_sum(pair) != 42) return 1;

    struct Hfa hfa = hfa_make(1.25, 2.5, 3.75);
    if (hfa.a != 1.25 || hfa.b != 2.5 || hfa.c != 3.75 || hfa_sum(hfa) != 7.5) return 2;
    hfa = hfa_relay(hfa);
    if (hfa.a != 2.25 || hfa.b != 4.5 || hfa.c != 6.75) return 3;

    struct Large large = large_make(10, 20, 12);
    if (large.a != 10 || large.b != 20 || large.c != 12 || large_sum(large) != 42) return 4;
    large = large_relay(large);
    if (large.a != 11 || large.b != 22 || large.c != 15) return 5;

    unsigned __int128 high = ((unsigned __int128)1) << 100;
    if (wide_add(high + 7, high + 5) != (high << 1) + 12) return 6;
    if (wide_relay(high + 7) != high + (((unsigned __int128)1) << 96) + 16) return 7;

    if (stack_pair(1, 2, 3, 4, 5, 6, 7, 8, pair) != 78) return 8;

    puts("PASS: AArch64 C ABI");
    return 0;
}
