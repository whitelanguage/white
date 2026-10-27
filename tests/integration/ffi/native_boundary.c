#include <stddef.h>

void *native_zero(void) { return NULL; }
void *native_echo(void *value) { return value; }
