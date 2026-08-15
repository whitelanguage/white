// Test: ERASED_STRUCT_MISMATCH
// File: tests/diagnostics/failures/test_erased_struct.wl
// Focus: Rejecting a concrete Struct restored as an unrelated type.
// Expected Error: "RuntimeError: Erased value has the wrong concrete type"

struct NumberBox(value: Int)
struct TextBox(value: String)

func erase(value: NumberBox) -> Struct {
    return value;
}

func main() -> Int {
    let value: TextBox = erase(NumberBox(7));
    return 0;
}
