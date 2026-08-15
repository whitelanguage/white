// Test: EMPTY_HEX_LITERAL
// File: tests/diagnostics/failures/test_empty_hex.wl
// Focus: Base-prefixed integer literals require at least one digit.
// Expected Error: "InvalidSyntax: Invalid numeric literal '0x'."

func main() -> Int {
    let value: Int = 0x;
    return value;
}
