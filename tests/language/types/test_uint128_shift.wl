// Test: UINT128_SHIFT
// File: tests/language/types/test_uint128_shift.wl
// Focus: Runtime 128-bit shifts across the 64-bit word boundary.

func left(value: UInt128, amount: UInt128) -> UInt128 {
    return value << amount;
}

func right(value: UInt128, amount: UInt128) -> UInt128 {
    return value >> amount;
}

func signed_right(value: Int128, amount: Int128) -> Int128 {
    return value >> amount;
}

func main() -> Int {
    let bit63: UInt128 = UInt128(1U) << UInt128(63U);
    let bit64: UInt128 = bit63 + bit63;
    let bit127: UInt128 = bit64 << UInt128(63U);

    if (left(UInt128(1U), UInt128(64U)) != bit64 ||
        left(UInt128(1U), UInt128(127U)) != bit127 ||
        right(bit64, UInt128(64U)) != UInt128(1U) ||
        right(bit127, UInt128(127U)) != UInt128(1U) ||
        signed_right(Int128(-2), Int128(1)) != Int128(-1)) {
        print("FAIL: UInt128 shifts across 64-bit words");
        return 1;
    }

    print("PASS: UInt128 shifts across 64-bit words");
    return 0;
}
