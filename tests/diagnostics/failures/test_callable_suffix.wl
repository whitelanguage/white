// Test: CALLABLE_SUFFIX
// File: tests/diagnostics/failures/test_callable_suffix.wl
// Focus: Parameters after a variadic callable pack require labels.
// Expected Error: " InvalidSyntax: Parameters after a variadic parameter in a callable type require labels. "

func main() -> Int {
    let callable: Function(String..., String) -> Void = null;
    return 0;
}
