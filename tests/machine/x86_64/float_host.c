// independent Win64 ABI checks
// MSVC-targeted Clang objects reference this floating-point ABI marker
int _fltused = 0;

extern double mixed(int a, double b, int c, float d, double e, float f);
extern float scalar(float value);
extern float u64_to_f32(unsigned long long value);
extern double u64_to_f64(unsigned long long value);
extern float negate_f32(float value);
extern double negate_f64(double value);
extern unsigned long long f32_to_u64(float value);
extern unsigned long long f64_to_u64(double value);
extern int cast_pressure_f32(float value, unsigned long long expected, unsigned long long expected_next);
extern int cast_pressure_f64(double value, unsigned long long expected, unsigned long long expected_next);

double host_mix(int a, double b, int c, float d, double e, float f) {
    return a + b * 10.0 + c * 100.0 + d * 1000.0 + e * 10000.0 + f * 100000.0;
}

float host_float(float a, double b, float c, double d, float e) {
    return (float)(a + b + c + d + e);
}

int host_roundtrip(void) {
    if (mixed(11, 1.5, 22, 2.25f, 3.5, 4.25f) != 11.5) {
        return 1;
    }
    if (scalar(2.5f) != 5.0f) {
        return 2;
    }
    // include exact ties and a low-bit sticky case on both sides of 2^63
    static const unsigned long long integers[] = {
        0ULL, 1ULL, 0xffffffffULL, 0x1fffffffffffffULL,
        0x20000000000001ULL, 0x7fffffffffffffffULL, 0x8000000000000000ULL,
        0x8000000000000400ULL, 0x8000000000000401ULL, 0x8000000000000c00ULL,
        0x8000008000000000ULL, 0x8000008000000001ULL, 0xffffffffffffffffULL
    };
    for (unsigned i = 0; i < sizeof(integers) / sizeof(integers[0]); ++i) {
        if (u64_to_f32(integers[i]) != (float)integers[i]) return 3;
        if (u64_to_f64(integers[i]) != (double)integers[i]) return 4;
    }
    static const double doubles[] = {
        0.0, -0.0, -0.75, 1.75, 4294967295.75, 0x1.fffffffffffffp62,
        0x1p63, 0x1.0000000000001p63, 0x1.fffffffffffffp63
    };
    for (unsigned i = 0; i < sizeof(doubles) / sizeof(doubles[0]); ++i) {
        if (f64_to_u64(doubles[i]) != (unsigned long long)doubles[i]) return 5;
    }
    static const float floats[] = {
        0.0f, -0.0f, -0.75f, 1.75f, 0x1p32f, 0x1.fffffep62f,
        0x1p63f, 0x1.000002p63f, 0x1.fffffep63f
    };
    for (unsigned i = 0; i < sizeof(floats) / sizeof(floats[0]); ++i) {
        if (f32_to_u64(floats[i]) != (unsigned long long)floats[i]) return 6;
    }
    if (cast_pressure_f32(4096.5f, 4096ULL, 4097ULL) != 0 ||
        cast_pressure_f32(0x1.000002p63f, 0x8000010000000000ULL, 0x8000010000000000ULL) != 0) return 7;
    if (cast_pressure_f64(123.75, 123ULL, 124ULL) != 0 ||
        cast_pressure_f64(0x1.0000000000001p63, 0x8000000000000800ULL, 0x8000000000000800ULL) != 0) return 8;
    // deterministic inputs cover the rest of the exponent and mantissa range
    unsigned long long state = 0x9e3779b97f4a7c15ULL;
    for (unsigned i = 0; i < 4096; ++i) {
        state = state * 6364136223846793005ULL + 1442695040888963407ULL;
        double d = (double)state;
        float f = (float)state;
        if (u64_to_f64(state) != d || u64_to_f32(state) != f) return 9;
        if (d < 0x1p64 && f64_to_u64(d) != (unsigned long long)d) return 10;
        if (f < 0x1p64f && f32_to_u64(f) != (unsigned long long)f) return 11;
        union { unsigned long long bits; double value; } input64, output64;
        union { unsigned bits; float value; } input32, output32;
        input64.bits = state;
        input32.bits = (unsigned)state;
        output64.value = negate_f64(input64.value);
        output32.value = negate_f32(input32.value);
        if (output64.bits != (input64.bits ^ 0x8000000000000000ULL)) return 12;
        if (output32.bits != (input32.bits ^ 0x80000000U)) return 13;
        output64.value = negate_f64(output64.value);
        output32.value = negate_f32(output32.value);
        if (output64.bits != input64.bits || output32.bits != input32.bits) return 14;
    }
    return 0;
}
