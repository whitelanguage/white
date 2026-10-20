// tests/machine/fixtures/transfers.c
#include <stdint.h>
#include <stdio.h>
#include <string.h>

struct Block257 { unsigned char data[257]; };
extern struct Block257 roundtrip257(struct Block257);
extern int64_t spill_sum(const int64_t *);
extern int64_t mixed_stack(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t,
    int64_t, const unsigned char *, struct Block257);
#define DECLARE(N) extern void copy##N(void *, const void *); extern void zero##N(void *);
DECLARE(65)
DECLARE(97)
DECLARE(257)
DECLARE(4096)

int64_t transfer_barrier(void) { return 7; }

static int check(int size, void (*copy)(void *, const void *), void (*zero)(void *)) {
    unsigned char src[4120], dst[4120];
    for (int i = 0; i < 4120; i++) src[i] = (unsigned char)(i * 37 + 11);
    memset(dst, 0xA5, sizeof dst);
    copy(dst + 3, src + 1);
    if (memcmp(dst + 3, src + 1, size) || dst[2] != 0xA5 || dst[3 + size] != 0xA5) return 1;
    zero(dst + 3);
    for (int i = 0; i < size; i++) if (dst[3 + i]) return 2;
    return dst[2] != 0xA5 || dst[3 + size] != 0xA5;
}

int main(void) {
    if (check(65, copy65, zero65) || check(97, copy97, zero97) ||
        check(257, copy257, zero257) || check(4096, copy4096, zero4096)) {
        puts("FAIL: transfer contents or guard bytes");
        return 1;
    }
    struct Block257 input;
    for (int i = 0; i < 257; i++) input.data[i] = (unsigned char)(i * 17 + 3);
    struct Block257 output = roundtrip257(input);
    if (memcmp(&input, &output, sizeof input)) { puts("FAIL: indirect result copy"); return 1; }
    unsigned char name = 7;
    if (mixed_stack(1, 2, 3, 4, 5, 6, 7, 8, 13, &name, input) != 23) {
        puts("FAIL: stack scalar followed by an indirect aggregate");
        return 1;
    }
    int64_t values[20];
    for (int i = 0; i < 20; i++) values[i] = i + 1;
    if (spill_sum(values) != 217) { puts("FAIL: call-live scalar spills"); return 1; }
    puts("PASS: native copy, zero, indirect result and scalar spill oracle");
    return 0;
}
