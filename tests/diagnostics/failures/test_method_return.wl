// Test: METHOD_RETURN_TYPE
// File: tests/diagnostics/failures/test_method_return.wl
// Focus: Requiring a return type for an empty Method signature.
// Expected Error: "InvalidSyntax: Method() requires a return type after '->'."

class Counter {
    func value() -> Int {
        return 1;
    }
}

func main() -> Int {
    let counter = Counter();
    let callback: Method() = counter.value;
    return 0;
}
