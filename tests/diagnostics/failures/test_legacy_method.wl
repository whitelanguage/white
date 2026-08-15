// Test: LEGACY_METHOD_KEYWORD
// File: tests/diagnostics/failures/test_legacy_method.wl
// Focus: Rejecting method declarations which do not use func.
// Expected Error: "InvalidSyntax: Use 'func' to declare class methods; 'method' was removed in White Language 0.3.5."

class Counter {
    method value() -> Int {
        return 1;
    }
}

func main() -> Int {
    return 0;
}
