// Test: WL_TO_WL_FFI_INTEROP
// File: tests/integration/ffi/test_dll_host.wl
// Focus: White Language calls across a shared-library boundary.
// Compile: wlc test_dll_host.wl test_lib_export.dll -o test_dll && ./test_dll


extern "C" {
    func add(a: Int, b: Int) -> Int;
    func factorial(n: Int) -> Int;
    func multiply_float(a: Float, b: Float) -> Float;
}

func main() -> Int {
    let res_add: Int = add(5, 7);
    let res_fact: Int = factorial(4);
    let res_float: Float = multiply_float(1.5, 4.0);

    let add_ok: Bool = (res_add == 12);
    let fact_ok: Bool = (res_fact == 24);
    let float_ok: Bool = (res_float == 6.0);

    if (add_ok && fact_ok && float_ok) {
        print("PASS: White Language FFI calls");
    } else {
        print("FAIL: White Language FFI call result");
        return 1;
    }

    return 0;
}
