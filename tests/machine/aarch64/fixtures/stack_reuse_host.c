// Test: AARCH64_STACK_REUSE_HOST
// File: tests/machine/aarch64/fixtures/stack_reuse_host.c
// Focus: Execute reused aggregate homes, cross-block values and addressed stack storage.

#include <stdint.h>
#include <stdio.h>

extern int64_t reuse(void);
extern int64_t preserve(void);
extern int64_t addressed(void);

int main(void) {
    if (reuse() != 255 || preserve() != 42 || addressed() != 42) { return 1; }
    puts("PASS: AArch64 stack reuse execution");
    return 0;
}
