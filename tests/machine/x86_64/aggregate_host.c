// Test: X86_64_AGGREGATE_HOST
// File: tests/machine/x86_64/aggregate_host.c
// Focus: Check Win64 POD register and stack arguments in both directions.

// clang's MSVC target emits this ABI marker for floating-point code
int _fltused = 0;

typedef struct { unsigned char value; } Byte;
typedef struct { unsigned short value; } Word;
typedef struct { unsigned int value; } Dword;
typedef struct { unsigned long long value; } Qword;
typedef struct { float value; } Float;
typedef struct { double value; } Double;

extern Byte native_byte(Byte);
extern Word native_word(Word);
extern Dword native_dword(Dword);
extern Qword native_qword(Qword);
extern Float native_float(Float);
extern Double native_double(Double);
extern Word native_fourth(Byte, double, Float, Word, Qword, Double);
extern Qword native_fifth(Byte, double, Float, Word, Qword, Double);
extern Double native_sixth(Byte, double, Float, Word, Qword, Double);
extern Qword native_zero(void);
extern Qword native_relay(Qword);
extern Qword native_twice(Qword);
typedef Qword (*Mix)(Qword, double, Dword, float, Qword, Double);
extern Qword native_indirect(Mix, Qword);

// O0 clang may copy a POD return through this helper; the fixture needs no CRT
void *memcpy(void *to, const void *from, unsigned long long size) {
    volatile unsigned char *destination = to;
    const volatile unsigned char *source = from;
    for (unsigned long long i = 0; i < size; ++i) destination[i] = source[i];
    return to;
}

#define LARGE_CASE(N) \
    typedef struct { unsigned char bytes[N]; } Large##N; \
    typedef Large##N (*LargeMix##N)(Large##N, double, Qword, float, Large##N, Double); \
    extern Large##N native_large_##N(Large##N, double, Qword, float, Large##N, Double); \
    extern Qword native_large_marker_##N(Large##N, double, Qword, float, Large##N, Double); \
    extern double native_large_float_##N(Large##N, double, Qword, float, Large##N, Double); \
    extern Large##N native_large_zero_##N(void); \
    extern Large##N native_large_relay_##N(Large##N); \
    extern Large##N native_large_twice_##N(Large##N); \
    extern Large##N native_large_indirect_##N(LargeMix##N, Large##N); \
    extern Large##N native_large_discard_##N(Large##N); \
    Large##N host_large_##N(Large##N a, double b, Qword c, float d, Large##N e, Double f) { \
        Large##N result; \
        for (int i = 0; i < N; ++i) result.bytes[i] = a.bytes[i] ^ e.bytes[i]; \
        unsigned char before = e.bytes[0]; \
        a.bytes[0] ^= 1; \
        if (e.bytes[0] != before || b != 2.5 || c.value != 123 || d != 1.25f || f.value != -9.5) result.bytes[0] = 255; \
        if (((unsigned long long)&a & 15) || ((unsigned long long)&e & 15)) result.bytes[0] = 255; \
        return result; \
    } \
    static int verify_large_##N(void) { \
        Large##N value, other; \
        for (int i = 0; i < N; ++i) { value.bytes[i] = (unsigned char)(i * 17 + 3); other.bytes[i] = (unsigned char)(i * 11 + 7); } \
        Large##N echo = native_large_##N(value, 2.5, (Qword){123}, 1.25f, other, (Double){-9.5}); \
        Large##N zero = native_large_zero_##N(); \
        Large##N relay = native_large_relay_##N(value); \
        Large##N twice = native_large_twice_##N(value); \
        Large##N indirect = native_large_indirect_##N(host_large_##N, value); \
        Large##N discard = native_large_discard_##N(value); \
        if (native_large_marker_##N(value, 2.5, (Qword){123}, 1.25f, other, (Double){-9.5}).value != 123) return 5; \
        if (native_large_float_##N(value, 2.5, (Qword){123}, 1.25f, other, (Double){-9.5}) != 2.5) return 6; \
        for (int i = 0; i < N; ++i) { \
            if (echo.bytes[i] != other.bytes[i] || zero.bytes[i] || relay.bytes[i] || indirect.bytes[i]) return 1; \
            if (twice.bytes[i] != value.bytes[i] || discard.bytes[i] != value.bytes[i]) return 2; \
        } \
        unsigned char guarded[N + 32]; \
        for (int i = 0; i < N + 32; ++i) guarded[i] = 0xa5; \
        typedef void *(*RawReturn)(void *); \
        void *returned = ((RawReturn)native_large_zero_##N)(guarded + 16); \
        if (returned != guarded + 16) return 3; \
        for (int i = 0; i < N + 32; ++i) { \
            if (guarded[i] != ((i < 16 || i >= N + 16) ? 0xa5 : 0)) return 4; \
        } \
        return 0; \
    }

LARGE_CASE(3)
LARGE_CASE(16)
LARGE_CASE(24)
LARGE_CASE(65)
LARGE_CASE(131)

Qword host_mix(Qword a, double b, Dword c, float d, Qword e, Double f) {
    if (b != 2.5 || c.value != 123456U || d != 1.25f || f.value != -9.5) {
        return (Qword){0};
    }
    return (Qword){a.value ^ e.value};
}

int host_verify(void) {
    unsigned long long bits = 0x123456789abcdef0ULL;
    static const unsigned long long special[] = {
        0ULL, 0x8000000000000000ULL, 0x7ff0000000000000ULL, 0xfff0000000000000ULL,
        0x7ff8000000000123ULL, 0x7ff0000000000123ULL, 0x80000000ULL,
        0x7f800000ULL, 0xff800000ULL, 0x7fc00123ULL, 0x7f800123ULL
    };
    for (int i = 0; i < 512; ++i) {
        // include signed zeros, infinities and NaN payloads without comparing them as numbers
        union { float value; unsigned int bits; } f, loaded_f;
        union { double value; unsigned long long bits; } d, loaded_d;
        if (i < (int)(sizeof(special) / sizeof(special[0]))) bits = special[i];
        f.bits = (unsigned int)bits;
        d.bits = bits;
        Byte b = {(unsigned char)bits};
        Word w = {(unsigned short)bits};
        Dword n = {(unsigned int)bits};
        Qword q = {bits};
        Float floating = {f.value};
        Double double_value = {d.value};
        if (native_byte(b).value != b.value) return 1;
        if (native_word(w).value != w.value) return 2;
        if (native_dword(n).value != n.value) return 3;
        if (native_qword(q).value != q.value) return 4;
        loaded_f.value = native_float(floating).value;
        loaded_d.value = native_double(double_value).value;
        if (loaded_f.bits != f.bits) return 5;
        if (loaded_d.bits != d.bits) return 6;
        if (native_fourth(b, 2.5, floating, w, q, double_value).value != w.value) return 7;
        if (native_fifth(b, 2.5, floating, w, q, double_value).value != q.value) return 8;
        loaded_d.value = native_sixth(b, 2.5, floating, w, q, double_value).value;
        if (loaded_d.bits != d.bits) return 9;
        if (native_relay(q).value != (bits ^ 0x123456789abcdef0ULL)) return 10;
        if (native_twice(q).value != bits) return 11;
        if (native_indirect(host_mix, q).value != (bits ^ 0x123456789abcdef0ULL)) return 12;
        bits ^= bits << 13;
        bits ^= bits >> 7;
        bits ^= bits << 17;
    }
    if (native_zero().value != 0) return 13;
    if (verify_large_3()) return 23;
    if (verify_large_16()) return 24;
    if (verify_large_24()) return 25;
    if (verify_large_65()) return 26;
    if (verify_large_131()) return 27;
    return 0;
}
