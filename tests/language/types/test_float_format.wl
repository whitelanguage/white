// Test: FLOAT_FORMAT
// File: tests/language/types/test_float_format.wl
// Focus: Formatting finite values beyond Long and rejecting non-finite JSON numbers.

import "json"

func from_bits(bits: UInt64) -> Float {
    let ptr value: Float = AnyPtr(ref bits);
    return deref value;
}

func main() -> Int {
    let large: Float = from_bits(0x43E0000000000000UL);
    if (String(large) != "9223372036854775808.000000" || String(-large) != "-9223372036854775808.000000") {
        print("FAIL: large Float format");
        return 1;
    }
    let huge: String = String(from_bits(0x7FEFFFFFFFFFFFFFUL));
    if (huge.length() != 316 || !huge.starts_with("1797693134862315708") || !huge.ends_with(".000000")) {
        print("FAIL: maximum Float format");
        return 1;
    }
    if (String(0.125) != "0.125000" || String(-2.5) != "-2.500000") {
        print("FAIL: ordinary Float format changed");
        return 1;
    }
    if (String(from_bits(0x7FF0000000000000UL)) != "inf" || String(from_bits(0xFFF0000000000000UL)) != "-inf" || String(from_bits(0x7FF8000000000000UL)) != "nan") {
        print("FAIL: non-finite Float format");
        return 1;
    }
    let value: json.Value = json.number(large)?;
    catch(err) { print("FAIL: finite JSON number"); return 1; }
    let encoded: String = json.encode(value)?;
    catch(err) { print("FAIL: finite JSON encoding"); return 1; }
    if (encoded != "9223372036854775808.000000") { print("FAIL: finite JSON text"); return 1; }
    json.number(from_bits(0x7FF0000000000000UL))?;
    catch(err) { print("PASS: Float format"); return 0; }
    print("FAIL: infinite JSON number accepted");
    return 1;
}
