// Test: NESTED_INFERENCE
// File: tests/language/types/test_nested_inference.wl
// Focus: Auto inference can resolve values declared outside a nested block.

import "builtin"

func main() -> Int {
    let values = [41, 42];
    let i = 0;

    while (i < values.length()) {
        let value = values[i];
        if (value == 42) {
            print("PASS: nested Auto inference");
            return 0;
        }
        i++;
    }

    print("FAIL: nested Auto inference");
    return 1;
}
