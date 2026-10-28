// tests/fixtures/native_fragments.c
#include <stdint.h>

typedef struct { uint8_t values[1]; } Bytes1;
Bytes1 native_bytes1(Bytes1 value) { value.values[0] += 100; return value; }
extern Bytes1 exported_bytes1(Bytes1);
typedef struct { uint8_t values[2]; } Bytes2;
Bytes2 native_bytes2(Bytes2 value) { value.values[0] += 100; return value; }
extern Bytes2 exported_bytes2(Bytes2);
typedef struct { uint8_t values[3]; } Bytes3;
Bytes3 native_bytes3(Bytes3 value) { value.values[0] += 100; return value; }
extern Bytes3 exported_bytes3(Bytes3);
typedef struct { uint8_t values[4]; } Bytes4;
Bytes4 native_bytes4(Bytes4 value) { value.values[0] += 100; return value; }
extern Bytes4 exported_bytes4(Bytes4);
typedef struct { uint8_t values[5]; } Bytes5;
Bytes5 native_bytes5(Bytes5 value) { value.values[0] += 100; return value; }
extern Bytes5 exported_bytes5(Bytes5);
typedef struct { uint8_t values[6]; } Bytes6;
Bytes6 native_bytes6(Bytes6 value) { value.values[0] += 100; return value; }
extern Bytes6 exported_bytes6(Bytes6);
typedef struct { uint8_t values[7]; } Bytes7;
Bytes7 native_bytes7(Bytes7 value) { value.values[0] += 100; return value; }
extern Bytes7 exported_bytes7(Bytes7);
typedef struct { uint8_t values[8]; } Bytes8;
Bytes8 native_bytes8(Bytes8 value) { value.values[0] += 100; return value; }
extern Bytes8 exported_bytes8(Bytes8);
typedef struct { uint8_t values[9]; } Bytes9;
Bytes9 native_bytes9(Bytes9 value) { value.values[0] += 100; return value; }
extern Bytes9 exported_bytes9(Bytes9);
typedef struct { uint8_t values[10]; } Bytes10;
Bytes10 native_bytes10(Bytes10 value) { value.values[0] += 100; return value; }
extern Bytes10 exported_bytes10(Bytes10);
typedef struct { uint8_t values[11]; } Bytes11;
Bytes11 native_bytes11(Bytes11 value) { value.values[0] += 100; return value; }
extern Bytes11 exported_bytes11(Bytes11);
typedef struct { uint8_t values[12]; } Bytes12;
Bytes12 native_bytes12(Bytes12 value) { value.values[0] += 100; return value; }
extern Bytes12 exported_bytes12(Bytes12);
typedef struct { uint8_t values[13]; } Bytes13;
Bytes13 native_bytes13(Bytes13 value) { value.values[0] += 100; return value; }
extern Bytes13 exported_bytes13(Bytes13);
typedef struct { uint8_t values[14]; } Bytes14;
Bytes14 native_bytes14(Bytes14 value) { value.values[0] += 100; return value; }
extern Bytes14 exported_bytes14(Bytes14);
typedef struct { uint8_t values[15]; } Bytes15;
Bytes15 native_bytes15(Bytes15 value) { value.values[0] += 100; return value; }
extern Bytes15 exported_bytes15(Bytes15);
typedef struct { uint8_t values[16]; } Bytes16;
Bytes16 native_bytes16(Bytes16 value) { value.values[0] += 100; return value; }
extern Bytes16 exported_bytes16(Bytes16);
typedef struct { uint8_t values[80]; } Bytes80;
Bytes80 native_bytes80(Bytes80 value) { value.values[0] += 100; return value; }
extern Bytes80 exported_bytes80(Bytes80);

int native_after_bulk(int a, int b, int c, Bytes80 value, int d, int e) {
    return a + b + c + value.values[79] + d + e;
}
extern int exported_after_bulk(int, int, int, Bytes80, int, int);

int native_fragment_exports(void) {
    Bytes1 v1 = {{0}};
    for (int i = 0; i < 1; i++) v1.values[i] = (uint8_t)(i + 1);
    Bytes1 r1 = exported_bytes1(v1);
    for (int i = 0; i < 1; i++) if (r1.values[i] != (uint8_t)(i + 1)) return 1;
    Bytes2 v2 = {{0}};
    for (int i = 0; i < 2; i++) v2.values[i] = (uint8_t)(i + 1);
    Bytes2 r2 = exported_bytes2(v2);
    for (int i = 0; i < 2; i++) if (r2.values[i] != (uint8_t)(i + 1)) return 2;
    Bytes3 v3 = {{0}};
    for (int i = 0; i < 3; i++) v3.values[i] = (uint8_t)(i + 1);
    Bytes3 r3 = exported_bytes3(v3);
    for (int i = 0; i < 3; i++) if (r3.values[i] != (uint8_t)(i + 1)) return 3;
    Bytes4 v4 = {{0}};
    for (int i = 0; i < 4; i++) v4.values[i] = (uint8_t)(i + 1);
    Bytes4 r4 = exported_bytes4(v4);
    for (int i = 0; i < 4; i++) if (r4.values[i] != (uint8_t)(i + 1)) return 4;
    Bytes5 v5 = {{0}};
    for (int i = 0; i < 5; i++) v5.values[i] = (uint8_t)(i + 1);
    Bytes5 r5 = exported_bytes5(v5);
    for (int i = 0; i < 5; i++) if (r5.values[i] != (uint8_t)(i + 1)) return 5;
    Bytes6 v6 = {{0}};
    for (int i = 0; i < 6; i++) v6.values[i] = (uint8_t)(i + 1);
    Bytes6 r6 = exported_bytes6(v6);
    for (int i = 0; i < 6; i++) if (r6.values[i] != (uint8_t)(i + 1)) return 6;
    Bytes7 v7 = {{0}};
    for (int i = 0; i < 7; i++) v7.values[i] = (uint8_t)(i + 1);
    Bytes7 r7 = exported_bytes7(v7);
    for (int i = 0; i < 7; i++) if (r7.values[i] != (uint8_t)(i + 1)) return 7;
    Bytes8 v8 = {{0}};
    for (int i = 0; i < 8; i++) v8.values[i] = (uint8_t)(i + 1);
    Bytes8 r8 = exported_bytes8(v8);
    for (int i = 0; i < 8; i++) if (r8.values[i] != (uint8_t)(i + 1)) return 8;
    Bytes9 v9 = {{0}};
    for (int i = 0; i < 9; i++) v9.values[i] = (uint8_t)(i + 1);
    Bytes9 r9 = exported_bytes9(v9);
    for (int i = 0; i < 9; i++) if (r9.values[i] != (uint8_t)(i + 1)) return 9;
    Bytes10 v10 = {{0}};
    for (int i = 0; i < 10; i++) v10.values[i] = (uint8_t)(i + 1);
    Bytes10 r10 = exported_bytes10(v10);
    for (int i = 0; i < 10; i++) if (r10.values[i] != (uint8_t)(i + 1)) return 10;
    Bytes11 v11 = {{0}};
    for (int i = 0; i < 11; i++) v11.values[i] = (uint8_t)(i + 1);
    Bytes11 r11 = exported_bytes11(v11);
    for (int i = 0; i < 11; i++) if (r11.values[i] != (uint8_t)(i + 1)) return 11;
    Bytes12 v12 = {{0}};
    for (int i = 0; i < 12; i++) v12.values[i] = (uint8_t)(i + 1);
    Bytes12 r12 = exported_bytes12(v12);
    for (int i = 0; i < 12; i++) if (r12.values[i] != (uint8_t)(i + 1)) return 12;
    Bytes13 v13 = {{0}};
    for (int i = 0; i < 13; i++) v13.values[i] = (uint8_t)(i + 1);
    Bytes13 r13 = exported_bytes13(v13);
    for (int i = 0; i < 13; i++) if (r13.values[i] != (uint8_t)(i + 1)) return 13;
    Bytes14 v14 = {{0}};
    for (int i = 0; i < 14; i++) v14.values[i] = (uint8_t)(i + 1);
    Bytes14 r14 = exported_bytes14(v14);
    for (int i = 0; i < 14; i++) if (r14.values[i] != (uint8_t)(i + 1)) return 14;
    Bytes15 v15 = {{0}};
    for (int i = 0; i < 15; i++) v15.values[i] = (uint8_t)(i + 1);
    Bytes15 r15 = exported_bytes15(v15);
    for (int i = 0; i < 15; i++) if (r15.values[i] != (uint8_t)(i + 1)) return 15;
    Bytes16 v16 = {{0}};
    for (int i = 0; i < 16; i++) v16.values[i] = (uint8_t)(i + 1);
    Bytes16 r16 = exported_bytes16(v16);
    for (int i = 0; i < 16; i++) if (r16.values[i] != (uint8_t)(i + 1)) return 16;
    Bytes80 v80 = {{0}};
    for (int i = 0; i < 80; i++) v80.values[i] = (uint8_t)(i + 1);
    Bytes80 r80 = exported_bytes80(v80);
    for (int i = 0; i < 80; i++) if (r80.values[i] != (uint8_t)(i + 1)) return 80;
    return exported_after_bulk(1, 2, 3, v80, 4, 5) == 95 ? 0 : 81;
}
