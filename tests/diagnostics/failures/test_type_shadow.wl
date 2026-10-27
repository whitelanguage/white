// Test: TYPE_SHADOW
// File: tests/diagnostics/failures/test_type_shadow.wl
// Focus: A shadowed intrinsic name must not hide mutations of a checked field.
// Expected Error: "before narrowing."

class Holder {
    let value: Optional(String);
    init() { self.value = "hello"; }
}

func change(holder: Holder, sample: Int) -> Bool {
    holder.value = null;
    return true;
}

func main() -> Int {
    let holder = Holder();
    let is_type = change;
    if (holder.value is !null && is_type(holder, 10)) {
        return holder.value.length();
    }
    return 0;
}
