#include <stdint.h>

struct Small { int32_t value; };
extern int64_t const_call(void);
extern int64_t const_edge(void);
extern struct Small const_small(void);
extern int32_t const_pointer(void);
extern uint8_t const_bytes(void);
extern uint8_t const_nested_bytes(void);

int main(void) {
    if (const_call() != 84 || const_edge() != 42 ||
        const_small().value != 42 || const_pointer() != 42 ||
        const_bytes() != 169 || const_nested_bytes() != 195) {
        return 1;
    }
    return 0;
}
