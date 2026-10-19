// compare machine-generated functions with the host's independent fmod implementation
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

extern double rem64(double x, double y);
extern float rem32(float x, float y);

static int check64(uint64_t a, uint64_t b) {
    double x, y, got, want;
    uint64_t actual, expected;
    memcpy(&x, &a, sizeof x);
    memcpy(&y, &b, sizeof y);
    got = rem64(x, y);
    want = fmod(x, y);
    memcpy(&actual, &got, sizeof actual);
    memcpy(&expected, &want, sizeof expected);
    if ((isnan(got) && isnan(want)) || actual == expected) return 1;
    printf("FAIL: f64 %016llx %% %016llx: %016llx != %016llx\n",
        (unsigned long long)a, (unsigned long long)b, (unsigned long long)actual, (unsigned long long)expected);
    return 0;
}

static int check32(uint32_t a, uint32_t b) {
    float x, y, got, want;
    uint32_t actual, expected;
    memcpy(&x, &a, sizeof x);
    memcpy(&y, &b, sizeof y);
    got = rem32(x, y);
    want = fmodf(x, y);
    memcpy(&actual, &got, sizeof actual);
    memcpy(&expected, &want, sizeof expected);
    if ((isnan(got) && isnan(want)) || actual == expected) return 1;
    printf("FAIL: f32 %08x %% %08x: %08x != %08x\n", a, b, actual, expected);
    return 0;
}

static uint64_t random_bits(uint64_t *state) {
    uint64_t x = *state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return *state = x;
}

int main(void) {
    const uint64_t edges64[] = {0, 0x8000000000000000ULL, 1, 3, 0x000fffffffffffffULL,
        0x0010000000000000ULL, 0x3ff0000000000000ULL, 0x4008000000000000ULL,
        0xc014000000000000ULL, 0x7fefffffffffffffULL, 0x7ff0000000000000ULL,
        0xfff0000000000000ULL, 0x7ff8000000000001ULL, 0x7ff0000000000001ULL};
    const uint32_t edges32[] = {0, 0x80000000U, 1, 3, 0x007fffffU, 0x00800000U,
        0x3f800000U, 0x40400000U, 0xc0a00000U, 0x7f7fffffU, 0x7f800000U,
        0xff800000U, 0x7fc00001U, 0x7f800001U};
    for (unsigned i = 0; i < sizeof edges64 / sizeof *edges64; i++) {
        for (unsigned j = 0; j < sizeof edges64 / sizeof *edges64; j++) {
            if (!check64(edges64[i], edges64[j]) || !check32(edges32[i], edges32[j]) ||
                !check64(edges64[i] ^ 0x8000000000000000ULL, edges64[j]) ||
                !check32(edges32[i] ^ 0x80000000U, edges32[j])) return 1;
        }
    }
    uint64_t state = 0xd1310ba698dfb5acULL;
    for (unsigned i = 0; i < 20000; i++) {
        uint64_t a = random_bits(&state), b = random_bits(&state);
        if (!check64(a, b) || !check32((uint32_t)a, (uint32_t)b)) return 1;
    }
    puts("PASS: native remainders match fmod, fmodf and signed-zero bits");
    return 0;
}
