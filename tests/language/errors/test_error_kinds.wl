// Test: STANDARD_ERROR_KINDS
// File: tests/language/errors/test_error_kinds.wl
// Focus: Keeping standard error kinds distinct and available through the prelude.

func main() -> Int {
    let kinds: Vector(Error) = [
        Error.InvalidArgument,
        Error.InvalidData,
        Error.Unsupported,
        Error.OutOfMemory,
        Error.IndexOutOfBounds,
        Error.TypeMismatch,
        Error.DivisionByZero,
        Error.Overflow,
        Error.Underflow
    ];

    let i: Int = 0;
    while (i < kinds.length()) {
        let j: Int = i + 1;
        while (j < kinds.length()) {
            if (kinds[i] == kinds[j]) {
                print("FAIL: Standard error kinds are not distinct");
                return 1;
            }
            j += 1;
        }
        i += 1;
    }

    print("PASS: Standard error kinds");
    return 0;
}
