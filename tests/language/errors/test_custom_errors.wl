// Test: USER_DEFINED_ERROR_DOMAINS
// File: tests/language/errors/test_custom_errors.wl
// Focus: Custom error declarations, propagation, and domain-aware comparison.

import Error from "errors"

error ParseError {
    UnexpectedToken,
    InvalidEscape = 7
}

error TransportError {
    UnexpectedToken
}

func parse(mode: Int) -> Int? {
    if (mode == 1) { throw ParseError.UnexpectedToken; }
    if (mode == 2) { throw ParseError.InvalidEscape; }
    if (mode == 3) { throw Error.InvalidArgument; }
    return 42;
}

func forward(mode: Int) -> Int? {
    let value: Int = parse(mode)?;
    return value;
}

func rethrow(mode: Int) -> Int? {
    let value: Int = parse(mode)?;
    catch(err) {
        throw err;
    }
    return value;
}

func catches_custom_domain() -> Bool {
    let value: Int = forward(1)?;
    catch(err) {
        return err == ParseError.UnexpectedToken &&
               err != TransportError.UnexpectedToken &&
               err != Error.InvalidArgument;
    }
    return value == 42;
}

func catches_explicit_code() -> Bool {
    let value: Int = rethrow(2)?;
    catch(err) {
        return err == ParseError.InvalidEscape && Int(err) == 7;
    }
    return value == 42;
}

func catches_standard_error() -> Bool {
    let value: Int = forward(3)?;
    catch(err) {
        return err == Error.InvalidArgument &&
               err != ParseError.UnexpectedToken;
    }
    return value == 42;
}

func succeeds_without_error() -> Bool {
    let value: Int = forward(0)?;
    catch(err) {
        return false;
    }
    return value == 42;
}

func main() -> Int {
    if (!catches_custom_domain() ||
        !catches_explicit_code() ||
        !catches_standard_error() ||
        !succeeds_without_error()) {
        print("FAIL: User-defined error domains");
        return 1;
    }

    print("PASS: User-defined error domains");
    return 0;
}
