// Test: X86_64_ATOMIC_ARC_HOST
// File: tests/machine/x86_64/atomic_arc_host.c
// Focus: Check atomic return values and the synthesized retain/release runtime.

extern int native_atomic_add(volatile int* address, int value);
extern int native_atomic_sub(volatile int* address, int value);
extern int native_atomic_exchange(volatile int* address, int value);
extern int native_atomic_and(volatile int* address, int value);
extern int native_atomic_or(volatile int* address, int value);
extern int native_atomic_xor(volatile int* address, int value);
extern int native_atomic_load(volatile int* address);
extern void native_atomic_store(volatile int* address, int value);
extern void native_arc_roundtrip(void* object);

static int deallocations;

void host_dealloc(void* object) {
    (void)object;
    ++deallocations;
}

int host_verify_atomic_arc(void) {
    volatile int value = 11;
    if (native_atomic_add(&value, 7) != 11 || value != 18) return 1;
    if (native_atomic_sub(&value, 5) != 18 || value != 13) return 2;
    if (native_atomic_exchange(&value, 29) != 13 || value != 29) return 3;
    if (native_atomic_and(&value, 15) != 29 || value != 13) return 4;
    if (native_atomic_or(&value, 32) != 13 || value != 45) return 5;
    if (native_atomic_xor(&value, 12) != 45 || value != 33) return 6;
    native_atomic_store(&value, 41);
    if (native_atomic_load(&value) != 41) return 7;

    unsigned long long storage[3] = {0, 0, 0};
    int* header = (int*)storage;
    header[2] = 2;
    native_arc_roundtrip((char*)storage + 16);
    if (header[2] != 2 || deallocations != 0) return 8;
    return 0;
}
