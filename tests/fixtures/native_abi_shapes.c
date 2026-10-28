// tests/fixtures/native_abi_shapes.c
typedef struct { float a, b; } NativeF2;
typedef struct { float a, b, c; } NativeF3;
typedef struct { double a, b, c, d; } NativeD4;
typedef struct { float a; long long b; } NativeMixed;
typedef struct { int a, b, c; } NativeI3;
typedef struct { __int128 value; } NativeWide;
/* White empty records occupy one byte, GNU C's zero-sized extension has a different layout. */
typedef struct { unsigned char storage; } NativeEmpty;

NativeF2 native_f2(NativeF2 v) { v.b += 2; return v; }
NativeF3 native_f3(NativeF3 v) { v.c += 3; return v; }
NativeD4 native_d4(NativeD4 v) { v.d += 4; return v; }
NativeMixed native_mixed(NativeMixed v) { v.b += 5; return v; }
NativeI3 native_gp_pressure(int a, int b, int c, int d, int e, NativeI3 v, int f) {
    v.c += a + b + c + d + e + f;
    return v;
}
NativeMixed native_fp_pressure(double a, double b, double c, double d, double e, double f, double g, double h, NativeMixed v, int tail) {
    v.b += (long long)(a+b+c+d+e+f+g+h) + tail;
    return v;
}
NativeF3 native_hfa_stack(double a, double b, double c, double d, double e, double f, double g, double h, NativeF3 v, int tail) {
    v.c += (float)(a+b+c+d+e+f+g+h) + tail;
    return v;
}
__int128 native_wide(__int128 value) { return value + 3; }
__int128 native_wide_pressure(int a, int b, int c, int d, int e, __int128 value, int tail) {
    return value + a + b + c + d + e + tail;
}
NativeWide native_wide_record(NativeWide v) { v.value += 7; return v; }
signed char native_narrow(signed char value) { return value - 1; }
NativeEmpty native_empty(NativeEmpty value, int tail) { value.storage = (unsigned char)tail; return value; }

extern NativeF2 exported_f2(NativeF2);
extern NativeF3 exported_f3(NativeF3);
extern NativeD4 exported_d4(NativeD4);
extern NativeMixed exported_mixed(NativeMixed);
extern NativeI3 exported_gp_pressure(int,int,int,int,int,NativeI3,int);
extern NativeMixed exported_fp_pressure(double,double,double,double,double,double,double,double,NativeMixed,int);
extern NativeF3 exported_hfa_stack(double,double,double,double,double,double,double,double,NativeF3,int);
extern __int128 exported_wide(__int128);
extern __int128 exported_wide_pressure(int,int,int,int,int,__int128,int);
extern NativeWide exported_wide_record(NativeWide);
extern int exported_narrow(signed char);
extern NativeEmpty exported_empty(NativeEmpty, int);

int native_shape_exports(void) {
    NativeF2 f2 = {1,2}; NativeF3 f3 = {1,2,3}; NativeD4 d4 = {1,2,3,4};
    NativeMixed mixed = {1.5f,20}; NativeI3 i3 = {10,20,30};
    __int128 big = ((__int128)1 << 100) + 7;
    NativeWide wide = {big};
    if (exported_f2(f2).b != 2 || exported_f3(f3).c != 3 || exported_d4(d4).d != 4) return 1;
    if (exported_mixed(mixed).b != 20) return 2;
    if (exported_gp_pressure(1,2,3,4,5,i3,6).c != 51) return 3;
    if (exported_fp_pressure(1,2,3,4,5,6,7,8,mixed,9).b != 65) return 4;
    if (exported_hfa_stack(1,2,3,4,5,6,7,8,f3,9).c != 48) return 5;
    if (exported_wide(big) != big || exported_wide_record(wide).value != big) return 6;
    if (exported_narrow(-11) != -11) return 7;
    if (exported_wide_pressure(1,2,3,4,5,big,6) != big + 21) return 8;
    NativeEmpty empty = {0};
    exported_empty(empty, 17);
    return 0;
}
