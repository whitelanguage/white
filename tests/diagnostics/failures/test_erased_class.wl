// Test: ERASED_CLASS_MISMATCH
// File: tests/diagnostics/failures/test_erased_class.wl
// Focus: Checking the concrete class before restoring an erased value.
// Expected Error: "RuntimeError: Erased value has the wrong concrete type"

class First { }
class Second { }

func make() -> Class { return First(); }

func main() -> Int {
    let value: Second = make();
    return 0;
}
