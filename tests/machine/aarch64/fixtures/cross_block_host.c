// Test: AARCH64_CROSS_BLOCK_HOST
// File: tests/machine/aarch64/fixtures/cross_block_host.c
// Focus: Execute native scalar, floating and UInt128 chains and both sides of a join.

#include <stdint.h>
#include <stdio.h>

extern int32_t scalar_chain(int32_t);
extern double float_chain(double);
extern unsigned __int128 wide_chain(unsigned __int128);
extern int32_t reordered(int32_t);
extern int32_t diamond(_Bool);
extern int32_t loop_value(void);

int32_t host_clobber(void) {
    __asm__ volatile(
        "mov x9, #9\n\tmov x10, #10\n\tmov x11, #11\n\t"
        "mov x12, #12\n\tmov x13, #13\n\tmov x14, #14\n\tmov x15, #15"
        : : : "x9", "x10", "x11", "x12", "x13", "x14", "x15");
    return 0;
}

int main(void) {
    if (scalar_chain(41) != 42 || float_chain(2.5) != 4.0) { return 1; }

    unsigned __int128 high = (unsigned __int128)1 << 100;
    unsigned __int128 carry = ((unsigned __int128)1 << 64) - 1;
    if (wide_chain(high) != high + 1 || wide_chain(carry) != carry + 1) { return 2; }
    if (reordered(41) != 42 || reordered(-2) != -1) { return 3; }
    if (diamond(0) != 42 || diamond(1) != 42) { return 4; }
    if (loop_value() != 1000) { return 5; }

    puts("PASS: AArch64 cross-block execution");
    return 0;
}
