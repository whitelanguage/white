// Test: UINT64_ARITHMETIC_AND_PROMOTION
// File: tests/language/types/test_uint64_arithmetic.wl
// Focus: Full-width unsigned arithmetic operations, compound assignments, bitwise shifts, and string formatting preservation for UInt64.


func main() -> Int {
    let maximum: UInt64 = 18446744073709551615UL;
    let quotient: UInt64 = maximum;
    quotient /= UInt64(10);

    let remainder: UInt64 = maximum % UInt64(10);
    let sum: UInt64 = UInt64(40) + UInt64(2);
    let shifted: UInt64 = maximum >> UInt64(63);

    if (quotient != 1844674407370955161UL ||
        remainder != UInt64(5) ||
        sum != UInt64(42) ||
        shifted != UInt64(1)) {
        print("FAIL: UInt64 arithmetic lost its type or signedness");
        return 1;
    }

    print("UInt64:" + maximum);
    print("PASS: UInt64 arithmetic and formatting");
    return 0;
}
