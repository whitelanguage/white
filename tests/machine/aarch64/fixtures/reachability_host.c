// Test: NATIVE_REACHABILITY_HOST
// File: tests/machine/aarch64/fixtures/reachability_host.c
// Focus: Follow nested data relocations and invoke an address-only callback on both targets.

#include <stdint.h>
#include <stdio.h>

struct table {
    int32_t tag;
    struct {
        int32_t *payload;
        int32_t (*callback)(void);
    } entry;
};

extern const struct table exported_table;
extern void *const cycle_a;
extern void *const cycle_b;
extern int32_t entry(void);

int32_t host_increment(int32_t value) {
    return value + 1;
}

int main(void) {
    if (entry() != 42 || exported_table.tag != 123 ||
        *exported_table.entry.payload != 7 || exported_table.entry.callback() != 8) {
        return 1;
    }
    if (cycle_a != &cycle_b || cycle_b != &cycle_a) {
        return 2;
    }
    puts("PASS: native reachable code and data execution");
    return 0;
}
