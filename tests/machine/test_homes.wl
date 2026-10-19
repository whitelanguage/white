// Test: STACK_HOMES
// File: tests/machine/test_homes.wl
// Focus: Expiry buckets for aligned SP and RBP stack homes.

import * from "../../src/compiler/machine/homes.wl"


func intervals(from_end: Bool) -> Bool {
    let pool = StackHomes(size=3, regions=[], free=null, ends=[]);
    stack_begin_block(ref pool, 5);
    let first = stack_reuse(ref pool, 8, 8, 1, from_end);
    let second = stack_reuse(ref pool, 16, 16, 2, from_end);
    if (first < 0 || second < 0 || first % 8 != 0 || second % 16 != 0) { return false; }

    stack_expire(ref pool, 1);
    let live = stack_reuse(ref pool, 8, 8, 3, from_end);
    if (live == first) { return false; }
    let size = pool.size;

    stack_expire(ref pool, 2);
    if (stack_reuse(ref pool, 8, 8, 4, from_end) != first) { return false; }
    stack_expire(ref pool, 3);
    if (stack_reuse(ref pool, 16, 16, 4, from_end) != second || pool.size != size) { return false; }
    stack_expire(ref pool, 4);
    stack_expire(ref pool, 5);

    stack_begin_block(ref pool, 2);
    if (stack_reuse(ref pool, 16, 16, 1, from_end) != second || pool.size != size) { return false; }
    if (stack_reuse(ref pool, 8, 8, 2, from_end) != -1) { return false; }

    pool.size = 2147483640;
    return stack_reserve(ref pool, 16, 16, from_end) == -1;
}

func main() -> Int {
    if (!intervals(false) || !intervals(true)) {
        print("FAIL: stack home expiry, alignment or overflow");
        return 1;
    }

    let pool = StackHomes(size=0, regions=[], free=null, ends=[]);
    stack_begin_block(ref pool, 4096);
    for (let i = 0; i < 4096; i++) {
        stack_expire(ref pool, i);
        if (stack_reuse(ref pool, 8, 8, i) != 0) {
            print("FAIL: sequential homes enlarged the stack");
            return 1;
        }
    }
    if (pool.size != 8 || pool.regions.length() != 1) { return 1; }

    print("PASS: shared stack home buckets");
    return 0;
}
