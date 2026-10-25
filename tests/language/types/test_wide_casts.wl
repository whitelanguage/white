// Test: WIDE_NUMERIC_CASTS
// File: tests/language/types/test_wide_casts.wl
// Focus: Converting signed and unsigned 128-bit values without external runtime helpers.
func to_float(value: Int128) -> Float { return Float(value); }
func to_float32(value: UInt128) -> Float32 { return Float32(value); }
func to_signed(value: Float) -> Int128 { return Int128(value); }
func to_unsigned(value: Float32) -> UInt128 { return UInt128(value); }

func main() -> Int {
    let negative: Int128 = -123456789LL;
    let wide: UInt128 = 1ULL << 100ULL;
    if (to_float(negative) != -123456789.0 || to_signed(to_float(negative)) != negative || to_unsigned(to_float32(wide)) != wide) {
        print("FAIL: wide numeric casts");
        return 1;
    }
    let min: Int128 = (-1LL) << 127LL;
    if (to_signed(to_float(min)) != min) {
        print("FAIL: signed 128-bit minimum");
        return 1;
    }
    let failures = 0;
    let invalid = -1.0;
    let unsigned = UInt128(invalid)?;
    catch(err) {
        if (err != Error.Overflow) { return 1; }
        failures++;
    }
    let limit = -to_float(min);
    let signed = Int128(limit)?;
    catch(err) {
        if (err != Error.Overflow) { return 1; }
        failures++;
    }
    let infinity = limit * limit * limit;
    let single = UInt128(Float32(infinity))?;
    catch(err) {
        if (err != Error.Overflow) { return 1; }
        failures++;
    }
    if (failures != 3 || to_signed(-0.0) != 0LL || to_unsigned(Float32(42.75)) != 42ULL) {
        print("FAIL: checked wide numeric casts");
        return 1;
    }
    print("PASS: wide numeric casts");
    return 0;
}
