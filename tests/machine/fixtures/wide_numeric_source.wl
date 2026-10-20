// Test: WIDE_NUMERIC_CASTS
// File: tests/machine/fixtures/wide_numeric_source.wl
// Focus: Convert 128-bit integers and floats, preserving checked-cast failures.

func signed_float(value: Int128) -> Float {
    return Float(value);
}

func unsigned_float(value: UInt128) -> Float {
    return Float(value);
}

func signed_single(value: Int128) -> Float32 {
    return Float32(value);
}

func unsigned_single(value: UInt128) -> Float32 {
    return Float32(value);
}

func signed_integer(value: Float) -> Int128 {
    return Int128(value);
}

func unsigned_integer(value: Float) -> UInt128 {
    return UInt128(value);
}

func main() -> Int {
    let large = 1LL << 100LL;
    let real: Float = 1.0;
    for (let bit = 0; bit < 100; bit++) { real *= 2.0; }
    if (signed_float(large) != real || unsigned_float(UInt128(large)) != real ||
        Float(signed_single(large)) != real || Float(unsigned_single(UInt128(large))) != real) {
        print("FAIL: wide integer to float");
        return 1;
    }
    if (signed_integer(-42.75) != -42LL || unsigned_integer(42.75) != 42ULL ||
        signed_integer(-real) != -large || unsigned_integer(real) != UInt128(large)) {
        print("FAIL: float to wide integer");
        return 1;
    }
    let single: Float32 = Float32(-42.75);
    if (Int128(single) != -42LL || UInt128(Float32(42.75)) != 42ULL) {
        print("FAIL: f32 to wide integer");
        return 1;
    }
    let zero = 0.0;
    if (Int128(-zero) != 0LL || UInt128(-zero) != 0ULL) {
        print("FAIL: negative zero conversion");
        return 1;
    }

    let failures = 0;
    let negative = -1.0;
    let unsigned = UInt128(negative)?;
    catch(err) {
        if (err != Error.Overflow) { return 1; }
        failures++;
    }
    let limit = signed_float(1LL << 126LL) * 2.0;
    let signed = Int128(limit)?;
    catch(err) {
        if (err != Error.Overflow) { return 1; }
        failures++;
    }
    let minimum = Int128(-limit);
    if (signed_float(minimum) != -limit) { return 1; }
    let infinity = limit * limit * limit;
    let rejected = UInt128(infinity)?;
    catch(err) {
        if (err != Error.Overflow) { return 1; }
        failures++;
    }
    if (failures != 3) {
        print("FAIL: wide cast overflow recovery");
        return 1;
    }
    print("PASS: checked wide numeric casts");
    return 0;
}
