#include <stdint.h>

typedef struct { uint8_t value; } NativeOne;
typedef struct { int16_t value; } NativeTwo;
typedef struct { float value; } NativeFloat;
typedef struct { int32_t left, right; } NativeEight;
typedef struct { uint8_t values[3]; } NativeThree;
typedef struct { int32_t left, middle, right; } NativeTwelve;
typedef struct { int64_t left, middle, right; } NativeLarge;
typedef struct { void *left, *right; } NativePair;

NativeOne native_one(NativeOne value) { value.value += 1; return value; }
NativeTwo native_two(NativeTwo value) { value.value += 2; return value; }
NativeFloat native_float(NativeFloat value) { value.value += 0.5f; return value; }
NativeEight native_eight(NativeEight value) { value.left += 3; value.right += 4; return value; }
NativeThree native_three(NativeThree value) { value.values[1] += 5; return value; }
NativeTwelve native_twelve(NativeTwelve value) { value.middle += 6; return value; }
NativeLarge native_large(int a, double b, NativeLarge value, int c, double d) {
    value.left += a + c;
    value.right += (int64_t)(b + d);
    return value;
}
NativePair native_pair(void *text) {
    NativePair value = {text, text};
    return value;
}
NativePair native_pair_null(void *text) {
    NativePair value = {text, 0};
    return value;
}
NativeTwelve native_variadic(NativeTwelve value, ...) { value.middle += 7; return value; }
NativeLarge native_system_large(int a, double b, NativeLarge value, int c, double d) {
    return native_large(a, b, value, c, d);
}

extern NativeOne exported_one(NativeOne);
extern NativeTwo exported_two(NativeTwo);
extern NativeFloat exported_float(NativeFloat);
extern NativeEight exported_eight(NativeEight);
extern NativeThree exported_three(NativeThree);
extern NativeTwelve exported_twelve(NativeTwelve);
extern NativeLarge exported_large(int, double, NativeLarge, int, double);

int native_aggregate_entries(void) {
    NativeOne one = {20};
    NativeTwo two = {400};
    NativeFloat f = {1.5f};
    NativeEight eight = {10, 20};
    NativeThree three = {{1, 2, 3}};
    NativeTwelve twelve = {10, 20, 30};
    NativeLarge large = {100, 200, 300};
    if (exported_one(one).value != 20) return 1;
    if (exported_two(two).value != 400) return 2;
    if (exported_float(f).value != 1.5f) return 3;
    eight = exported_eight(eight);
    if (eight.left != 10 || eight.right != 20) return 4;
    three = exported_three(three);
    if (three.values[0] != 1 || three.values[1] != 2 || three.values[2] != 3) return 5;
    twelve = exported_twelve(twelve);
    if (twelve.left != 10 || twelve.middle != 20 || twelve.right != 30) return 6;
    NativeLarge result = exported_large(1, 2.0, large, 3, 4.0);
    if (result.left != 104 || result.middle != 200 || result.right != 306 || large.left != 100) return 7;
    return 0;
}
