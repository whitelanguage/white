// Test: HEAP_ALIGNMENT
// File: tests/language/memory/test_heap_alignment.wl
// Focus: Wide integers remain aligned when heap storage grows.

import "sys"


func main() -> Int {
    let values: Vector(UInt128) = [];
    let high: UInt128 = UInt128(1U) << 100;
    let i: Int = 0;
    while (i < 513) {
        values.append(high | UInt128(i));
        if (sys.OS == sys.Os.Windows && (UIntSize(ref values[0]) & UIntSize(15)) != UIntSize(0)) {
            print("FAIL: UInt128 vector storage is not sixteen-byte aligned");
            return 1;
        }
        i++;
    }

    i = 0;
    while (i < values.length()) {
        if (values[i] != (high | UInt128(i))) {
            print("FAIL: vector growth changed a wide integer");
            return 1;
        }
        i++;
    }
    print("PASS: wide integer heap alignment");
    return 0;
}
