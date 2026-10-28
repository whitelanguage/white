// Test: NATIVE_IMPORT_SHADOW
// File: tests/integration/ffi/test_native_import_shadow.wl
// Focus: A local source function shadows an imported native spelling.
// Link: native_boundary.c

import * from "../../fixtures/native_callable.wl"
import native_sum as imported_sum from "../../fixtures/native_callable.wl"


func native_sum() -> Int { return 42; }

func main() -> Int {
    if (native_sum() != 42) { return 1; }
    if (imported_sum(1, 2, 3, 4, 5, 6, 7, 8) != 204) { return 2; }
    let local = native_sum;
    if (local() != 42) { return 3; }
    print("PASS: native import shadow");
    return 0;
}
