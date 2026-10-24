// Test: STRUCT_DEFAULT_ORDER
// File: tests/diagnostics/failures/test_struct_default_order.wl
// Focus: Required fields cannot follow fields with defaults in the constructor signature.
// Expected Error: "InvalidSyntax: A required parameter cannot follow a parameter with a default value."

struct Count(value: Int = 0, required: Int)

func main() -> Int {
    return 0;
}
