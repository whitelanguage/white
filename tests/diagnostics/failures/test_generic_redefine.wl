// Test: GENERIC_REDEFINITION
// File: tests/diagnostics/failures/test_generic_redefine.wl
// Focus: Rejecting generic and non-generic functions that share a source name.
// Expected Error: "NameError: Function 'identity' is already defined."

func identity(value: Int) -> Int {
    return value;
}

func identity<T>(value: T) -> T {
    return value;
}

func main() -> Int {
    return identity(1);
}
