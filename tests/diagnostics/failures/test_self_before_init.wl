// Test: CLASS_SELF_BEFORE_INITIALIZATION
// File: tests/diagnostics/failures/test_self_before_init.wl
// Focus: Preventing self from escaping before every field is initialized.
// Expected Error: "MissingInitializer: Cannot use 'self' before all fields of 'Escaping' are initialized."

class Escaping {
    let value: Int;

    init() -> Void {
        observe(self);
        self.value = 1;
    }
}

func observe(value: Escaping) -> Void {
}

func main() -> Int {
    return 0;
}
