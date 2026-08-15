// Test: SIGNED_UNSIGNED_MIX
// File: tests/diagnostics/failures/test_signed_mix.wl
// Focus: Requiring explicit conversion between signed and unsigned variables.
// Expected Error: "TypeError: Cannot mix signed and unsigned integers without an explicit conversion"

func main() -> Int { let signed: Int = -1; let unsigned: UInt32 = 1U; if (signed < unsigned) { return 1; } return 0; }
