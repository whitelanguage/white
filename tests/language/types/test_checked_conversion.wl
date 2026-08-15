// Test: CHECKED_EXPLICIT_CONVERSION
// File: tests/language/types/test_checked_conversion.wl
// Focus: Range checks and catchable failures in explicit built-in conversions.

import Error from "errors"

func to_byte(value: Int) -> Int {
    let result: Byte = Byte(value)?;
    catch(err) {
        if (err == Error.Overflow) { return -1; }
        return -2;
    }
    return Int(result);
}

func to_int(value: Float) -> Int {
    let result: Int = Int(value)?;
    catch(err) {
        if (err == Error.Overflow) { return -1; }
        return -2;
    }
    return result;
}

func to_char(value: Int) -> Bool {
    let result: Char = Char(value)?;
    catch(err) {
        return err == Error.Overflow;
    }
    return result == 'A';
}

func to_bool(value: Int) -> Bool {
    let result: Bool = Bool(value)?;
    catch(err) {
        return err == Error.Overflow;
    }
    return result;
}

func main() -> Int {
    if (to_byte(255) != 255 || to_byte(256) != -1 || to_byte(-1) != -1) { return 1; }
    if (to_int(42.9) != 42 || to_int(100000000000000000000.0) != -1) { return 2; }
    if (!to_char(65) || !to_char(55296) || !to_char(1114112)) { return 3; }
    if (!to_bool(1) || !to_bool(2)) { return 4; }

    print("PASS: checked explicit conversions");
    return 0;
}
