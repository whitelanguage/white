// std/internal/runtime/format.wl
// formatting hooks used by compiler-generated conversions

import "internal/runtime/string" as runtime_string

func signed_decimal_digits(value: Long) -> Int {
    let probe: Long = value;
    let digits: Int = 1;
    while (probe <= -10L || probe >= 10L) {
        probe /= 10L;
        digits += 1;
    }
    if (value < 0L) { digits += 1; }
    return digits;
}

@CompilerLink("format_long")
func format_long(value: Long) -> String {
    let length: Int = signed_decimal_digits(value);
    let result: String = runtime_string.alloc(Long(length));
    if (result is null) { return null; }

    let ptr output: Byte = runtime_string.data(result);
    let negative: Bool = value < 0L;
    // stay negative so Long.MIN does not overflow
    let work: Long = value;
    if (!negative) { work = 0L - work; }

    let pos: Int = length - 1;
    while true {
        let digit: Int = Int(0L - (work % 10L));
        output[pos] = Byte(digit + 48);
        work /= 10L;
        if (work == 0L) { break; }
        pos -= 1;
    }
    if negative { output[0] = Byte(45); }
    return result;
}

@CompilerLink("format_int")
func format_int(value: Int) -> String {
    return format_long(Long(value));
}

@CompilerLink("format_uint64")
func format_uint64(value: UInt64) -> String {
    let probe: UInt64 = value;
    let length: Int = 1;
    while (probe >= UInt64(10)) {
        probe /= UInt64(10);
        length += 1;
    }

    let result: String = runtime_string.alloc(Long(length));
    if (result is null) { return null; }
    let ptr output: Byte = runtime_string.data(result);
    let work: UInt64 = value;
    let pos: Int = length - 1;
    while true {
        output[pos] = Byte(Int(work % UInt64(10)) + 48);
        work /= UInt64(10);
        if (work == UInt64(0)) { break; }
        pos -= 1;
    }
    return result;
}

@CompilerLink("format_int128")
func format_int128(value: Int128) -> String {
    let negative: Bool = value < Int128(0);
    let magnitude: UInt128 = UInt128(0);
    if negative {
        let adjusted: Int128 = Int128(0) - (value + Int128(1));
        magnitude = UInt128(adjusted) + UInt128(1);
    } else {
        magnitude = UInt128(value);
    }
    return format_uint128_magnitude(magnitude, negative);
}

@CompilerLink("format_uint128")
func format_uint128(value: UInt128) -> String {
    return format_uint128_magnitude(value, false);
}

func format_uint128_magnitude(value: UInt128, negative: Bool) -> String {
// convert four base-2^32 limbs into five base-10^9 chunks
    let storage: String = runtime_string.alloc(20L);
    if (storage is null) { return null; }
    let ptr chunks: UInt32 = runtime_string.data(storage);
    let clear_idx: Int = 0;
    while (clear_idx < 5) {
        chunks[clear_idx] = UInt32(0);
        clear_idx += 1;
    }

    let limb_idx: Int = 3;
    while (limb_idx >= 0) {
        let limb: UInt128 = (value >> UInt128(limb_idx * 32)) & UInt128(4294967295UL);
        let carry: UInt64 = UInt64(UInt32(limb));
        let chunk_idx: Int = 0;
        while (chunk_idx < 5) {
            let current: UInt64 = UInt64(chunks[chunk_idx]) * 4294967296UL + carry;
            chunks[chunk_idx] = UInt32(current % 1000000000UL);
            carry = current / 1000000000UL;
            chunk_idx += 1;
        }
        limb_idx -= 1;
    }

    let highest: Int = 4;
    while (highest > 0 && chunks[highest] == UInt32(0)) { highest -= 1; }
    let leading: UInt32 = chunks[highest];
    let leading_digits: Int = 1;
    while (leading >= UInt32(10)) {
        leading /= UInt32(10);
        leading_digits += 1;
    }
    let digit_count: Int = highest * 9 + leading_digits;
    let length: Int = digit_count;
    if negative { length += 1; }

    let result: String = runtime_string.alloc(Long(length));
    if (result is null) { return null; }
    let ptr output: Byte = runtime_string.data(result);

    if negative {
        output[0] = Byte(45);
    }

    let output_pos: Int = length - 1;
    let chunk_idx: Int = 0;
    while (chunk_idx <= highest) {
        let chunk: UInt32 = chunks[chunk_idx];
        let width: Int = 9;
        if (chunk_idx == highest) { width = leading_digits; }
        let digit_idx: Int = 0;
        while (digit_idx < width) {
            output[output_pos] = Byte(Int(chunk % UInt32(10)) + 48);
            chunk /= UInt32(10);
            output_pos -= 1;
            digit_idx += 1;
        }
        chunk_idx += 1;
    }
    return result;
}

@CompilerLink("format_float")
func format_float(value: Float) -> String {
    let negative: Bool = value < 0.0;
    if negative { value = -value; }

    let whole_value: Long = Long(value);
    let fraction_value: Long = Long((value - Float(whole_value)) * 1000000.0 + 0.5);
    if (fraction_value >= 1000000L) {
        whole_value += 1L;
        fraction_value -= 1000000L;
    }

    let whole: String = format_long(whole_value);
    if negative {
        let signed_whole: String = runtime_string.alloc(Long(whole.length()) + 1L);
        if (signed_whole is null) { return null; }
        let ptr signed_bytes: Byte = runtime_string.data(signed_whole);
        let ptr whole_bytes: Byte = runtime_string.data(whole);
        signed_bytes[0] = Byte(45);
        let i: Int = 0;
        while (i < whole.length()) {
            signed_bytes[i + 1] = whole_bytes[i];
            i += 1;
        }
        whole = signed_whole;
    }

    let fraction: String = runtime_string.alloc(7L);
    if (fraction is null) { return null; }
    let ptr output: Byte = runtime_string.data(fraction);
    output[0] = Byte(46);

    let pos: Int = 6;
    while (pos >= 1) {
        output[pos] = Byte(Int(fraction_value % 10L) + 48);
        fraction_value /= 10L;
        pos -= 1;
    }
    let result: String = runtime_string.alloc(Long(whole.length() + fraction.length()));
    if (result is null) { return null; }
    let ptr result_bytes: Byte = runtime_string.data(result);
    let ptr whole_bytes: Byte = runtime_string.data(whole);
    let ptr fraction_bytes: Byte = runtime_string.data(fraction);
    let i: Int = 0;
    while (i < whole.length()) {
        result_bytes[i] = whole_bytes[i];
        i += 1;
    }
    let j: Int = 0;
    while (j < fraction.length()) {
        result_bytes[whole.length() + j] = fraction_bytes[j];
        j += 1;
    }
    return result;
}
