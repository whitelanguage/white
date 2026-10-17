// Test: AARCH64_EDGE_MOVES_HOST
// File: tests/machine/aarch64/fixtures/edge_moves_host.c
// Focus: Execute the same joins and scalar/wide/aggregate rotations through both native backends.

#include <stdint.h>
#include <stdio.h>

struct record { int64_t a, b; };
extern int32_t edge_join(_Bool, int32_t, int32_t, int32_t);
extern double edge_float(double, double);
extern int32_t edge_int_loop(int32_t);
extern unsigned __int128 edge_wide_loop(int32_t);
extern double edge_float_loop(int32_t);
extern struct record edge_record_loop(int32_t);

int main(void) {
    if (edge_join(1, 1, 2, 3) != 231 || edge_join(0, 1, 2, 3) != 221) { return 1; }
    if (edge_join(1, -1, -2, -3) != -231 || edge_float(3.0, 4.0) != 54.0) { return 2; }
    unsigned __int128 high = (unsigned __int128)1 << 100;
    for (int i = 0; i < 100; ++i) {
        int value = i % 3 + 1;
        if (edge_int_loop(i) != value || edge_wide_loop(i) != high + value ||
            edge_float_loop(i) != value + 0.5) { return 3; }
        struct record result = edge_record_loop(i);
        if (result.a != value || result.b != value % 3 + 1) { return 4; }
    }
    puts("PASS: parallel edge transfers");
    return 0;
}
