// tests/fixtures/native_varargs.c
#include <stdarg.h>
#include <stdint.h>

typedef struct { int32_t a, b, c; } VaRecord;

double native_va_pairs(float prefix, int count, ...) {
    va_list ap;
    va_start(ap, count);
    double result = prefix;
    for (int i = 0; i < count; i++) {
        result += va_arg(ap, int);
        result += va_arg(ap, double);
    }
    va_end(ap);
    return result;
}

VaRecord native_va_record(VaRecord record, int count, ...) {
    va_list ap;
    va_start(ap, count);
    for (int i = 0; i < count; i++) {
        record.b += va_arg(ap, int);
        record.c += (int32_t)va_arg(ap, double);
    }
    va_end(ap);
    return record;
}

int native_va_pointer(int expected, ...) {
    va_list ap;
    va_start(ap, expected);
    const int *value = va_arg(ap, const int *);
    va_end(ap);
    return *value == expected;
}

int native_va_wide(int count, ...) {
    va_list ap;
    va_start(ap, count);
    __int128 value = va_arg(ap, __int128);
    va_end(ap);
    return value == (((__int128)1 << 100) + 7);
}
