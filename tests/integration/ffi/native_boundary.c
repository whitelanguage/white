#include <stddef.h>

void *native_zero(void) { return NULL; }
void *native_echo(void *value) { return value; }
void *native_text(void *value) { return value; }
void native_increment(int *value) { ++*value; }

int native_sum(int a, int b, int c, int d, int e, int f, int g, int h) {
    return a + 2*b + 3*c + 4*d + 5*e + 6*f + 7*g + 8*h;
}

int native_ten(int a, int b, int c, int d, int e, int f, int g, int h, int i, int j) {
    return a + b + c + d + e + f + g + h + i + j;
}

double native_mix(int a, double b, int c, double d, int e, double f,
                  int g, double h, int i, double j) {
    return a + b + c + d + e + f + g + h + i + j;
}

static int last_value;
void native_set(int value) { last_value = value; }
int native_get(void) { return last_value; }

#if defined(_WIN32)
int __stdcall native_system(int a, int b) { return a - b; }
#else
int native_system(int a, int b) { return a - b; }
#endif
