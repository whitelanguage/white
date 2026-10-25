// Test: INVALID_CLASS_MEMBER
// File: tests/diagnostics/failures/test_class_member.wl
// Focus: Invalid class members terminate parser recovery instead of looping.
// Expected Error: "InvalidSyntax: Expected a field, method, conversion, init, or deinit declaration."

class Broken {
    return;
}

func main() -> Int {
    return 0;
}
