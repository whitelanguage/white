// Test: SYSTEM_ABI_VARARGS_REJECTED
// File: tests/diagnostics/failures/test_system_varargs.wl
// Focus: Enforcement that variadic arguments (...) are restricted exclusively to the C ABI.
// Expected Error: "ExternError: Variadic extern functions require the C ABI."

extern "system" {
    func invalid_system_varargs(tag: Int, ...) -> Int;
}

func main() -> Int {
    return 0;
}
