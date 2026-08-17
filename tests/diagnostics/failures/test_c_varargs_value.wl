// Test: C_VARARGS_VALUE
// File: tests/diagnostics/failures/test_c_varargs_value.wl
// Focus: C variadic declarations cannot be stored as White Language Function values.
// Expected Error: " TypeError: A C variadic function cannot be used as a White Language Function value. "

extern "C" {
    func trace(ptr format: Int8, ...) -> Int;
}

func main() -> Int {
    let callable = trace;
    return 0;
}
