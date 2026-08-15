// Test: CLASS_FIELD_EARLY_READ
// File: tests/diagnostics/failures/test_field_early_read.wl
// Focus: Rejecting reads from class fields before initialization.
// Expected Error: "MissingInitializer: Field 'value' is read before it is initialized."

class EarlyRead {
    let value: Int;

    init() -> Void {
        let previous: Int = self.value;
        self.value = previous;
    }
}

func main() -> Int {
    return 0;
}
