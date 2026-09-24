// Test: X86_64_SAFETY_CHECKS_HOST
// File: tests/machine/x86_64/safety_host.c
// Focus: Exercise successful checks and each native trap path independently.

extern void* native_null_checked(void* value);
extern long long native_bounds_i64(long long index, long long limit);
extern unsigned long long native_bounds_u64(unsigned long long index, unsigned long long limit);
extern void native_trap(void);
extern void native_unreachable(void);

int host_verify_safety(void) {
#if defined(TEST_NULL_TRAP)
    (void)native_null_checked((void*)0);
#elif defined(TEST_SIGNED_LOW_TRAP)
    (void)native_bounds_i64(-1, 4);
#elif defined(TEST_SIGNED_HIGH_TRAP)
    (void)native_bounds_i64(4, 4);
#elif defined(TEST_UNSIGNED_TRAP)
    (void)native_bounds_u64(8, 8);
#elif defined(TEST_TRAP)
    native_trap();
#elif defined(TEST_UNREACHABLE)
    native_unreachable();
#else
    int value = 7;
    if (native_null_checked(&value) != &value) return 1;
    if (native_bounds_i64(0, 4) != 0 || native_bounds_i64(3, 4) != 3) return 2;
    if (native_bounds_u64(0, 9) != 0 || native_bounds_u64(8, 9) != 8) return 3;
    return 0;
#endif
    return 1;
}
