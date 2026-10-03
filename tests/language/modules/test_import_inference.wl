// Test: IMPORT_INFERENCE
// File: tests/language/modules/test_import_inference.wl
// Focus: Inferring imported function results and chained calls.

import label from "../../fixtures/modules/left/provider.wl"

func imported_length() -> Int {
    return label().length();
}

func stored_length() -> Int {
    let value = label();
    return value.length();
}

func main() -> Int {
    let value = label();
    let length = label().length();
    if (value != "left" || length != 4 || imported_length() != 4 || stored_length() != 4) {
        print("FAIL: Imported function inference");
        return 1;
    }
    print("PASS: Imported function inference");
    return 0;
}
