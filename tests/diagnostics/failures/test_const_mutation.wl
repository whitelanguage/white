// Test: CONST_IMMUTABILITY_VIOLATION
// File: tests/diagnostics/failures/test_const_mutation.wl
// Focus: Ensuring symbols declared with 'const' cannot be reassigned or mutated.
// Expected Error: "TypeError: Cannot modify constant variable 'VERSION'."

const VERSION: Int = 1;

func main() -> Int {
    // intentional mutation error
    VERSION++; 
    return 0;
}
