// independent Win64 ABI checks
// MSVC-targeted Clang objects reference this floating-point ABI marker
int _fltused = 0;

extern double mixed(int a, double b, int c, float d, double e, float f);
extern float scalar(float value);

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
    return 0;
}
