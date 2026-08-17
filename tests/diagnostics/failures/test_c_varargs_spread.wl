// Test: C_VARARGS_SPREAD
// File: tests/diagnostics/failures/test_c_varargs_spread.wl
// Focus: White Language argument packs cannot be expanded into a C variadic call.
// Expected Error: " InvalidSyntax: Argument expansion is not available when calling a C variadic function. "

extern "C" {
    func trace(ptr format: Int8, ...) -> Int;
}

func call_trace(values: Int...) -> Int {
    return trace(nullptr, values...);
}

func main() -> Int {
    return 0;
}
