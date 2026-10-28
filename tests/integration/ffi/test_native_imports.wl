// Test: NATIVE_IMPORTS
// File: tests/integration/ffi/test_native_imports.wl
// Focus: Binding extern declarations and reexports before function bodies.
// Link: native_boundary.c

import * from "../../fixtures/native_callable.wl"
import native_sum as explicit_sum from "../../fixtures/native_callable.wl"
import sum as forwarded_sum from "../../fixtures/native_package/_pkg.wl"
import "../../fixtures/native_callable.wl" as native


func main() -> Int {
    if (native_sum(1, 2, 3, 4, 5, 6, 7, 8) != 204) { return 1; }
    if (explicit_sum(1, 2, 3, 4, 5, 6, 7, 8) != 204) { return 2; }
    if (forwarded_sum(1, 2, 3, 4, 5, 6, 7, 8) != 204) { return 3; }
    if (native.native_sum(1, 2, 3, 4, 5, 6, 7, 8) != 204) { return 4; }

    let call = native_sum;
    let forwarded: Function(Int, Int, Int, Int, Int, Int, Int, Int) -> Int = forwarded_sum;
    if (call(1, 2, 3, 4, 5, 6, 7, 8) != 204) { return 5; }
    if (forwarded(1, 2, 3, 4, 5, 6, 7, 8) != 204) { return 6; }
    print("PASS: native imports");
    return 0;
}
