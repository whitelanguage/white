// Test: LONG_DIVISION
// File: tests/language/types/test_long_division.wl
// Focus: Full-width signed and unsigned division on native and 32-bit targets.

func main() -> Int {
    let signed_max: Long = 9223372036854775807L;
    let signed_min_plus_one: Long = -9223372036854775807L;
    let unsigned_max: UInt64 = 18446744073709551615UL;

    let signed_ok: Bool = signed_max / 10L == 922337203685477580L && signed_max % 10L == 7L && signed_min_plus_one / 2147483649L == -4294967294L && signed_min_plus_one % 2147483649L == -1L;
    let sign_ok: Bool = signed_max / -10L == -922337203685477580L && signed_max % -10L == 7L && signed_min_plus_one / -10L == 922337203685477580L && signed_min_plus_one % -10L == -7L;
    let unsigned_ok: Bool = unsigned_max / 4294967297UL == 4294967295UL && unsigned_max % 4294967297UL == UInt64(0) && UInt64(7) / UInt64(11) == UInt64(0) && UInt64(7) % UInt64(11) == UInt64(7);

    if (!signed_ok || !sign_ok || !unsigned_ok) {
        print("FAIL: 64-bit division returned the wrong result");
        return 1;
    }
    print("PASS: 64-bit division");
    return 0;
}
