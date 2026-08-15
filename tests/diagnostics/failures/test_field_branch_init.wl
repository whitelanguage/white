// Test: CLASS_FIELD_BRANCH_INITIALIZATION
// File: tests/diagnostics/failures/test_field_branch_init.wl
// Focus: Requiring class fields to be initialized on every constructor path.
// Expected Error: "MissingInitializer: Field 'value' is not initialized on every path through 'Branch.init'."

class Branch {
    let value: Int;

    init(enabled: Bool) -> Void {
        if enabled {
            self.value = 1;
        }
    }
}

func main() -> Int {
    return 0;
}
