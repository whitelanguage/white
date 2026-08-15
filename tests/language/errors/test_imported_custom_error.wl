// Test: IMPORTED_USER_ERROR
// File: tests/language/errors/test_imported_custom_error.wl
// Focus: Error-domain identity survives named imports and function boundaries.

import WireError from "../../fixtures/errors/custom_error_source.wl"
import fail_wire from "../../fixtures/errors/custom_error_source.wl"

func receives_imported_error() -> Bool {
    let value: Int = fail_wire()?;
    catch(err) {
        return err == WireError.InvalidFrame &&
               err != WireError.Disconnected;
    }
    return value == 0;
}

func main() -> Int {
    if (!receives_imported_error()) {
        print("FAIL: Imported user error");
        return 1;
    }
    print("PASS: Imported user error");
    return 0;
}
